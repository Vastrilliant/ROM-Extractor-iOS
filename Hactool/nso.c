#include "ios_shim.h"
#include <string.h>
#include <limits.h>
#include "nso.h"
#include "lz4.h"
#include "sha.h"

static int nso_process_segments(nso0_ctx_t *ctx, const nso0_header_t *source_header) {
    filepath_t *output_path = &ctx->tool_ctx->settings.uncompressed_path;
    int write_output = (ctx->tool_ctx->action & ACTION_EXTRACT) && output_path->valid == VALIDITY_VALID;
    nso0_header_t output_header = *source_header;
    uint64_t output_size = sizeof(nso0_header_t);

    for (unsigned int i = 0; i < 3; i++) {
        uint64_t output_offset = (uint64_t)source_header->segments[i].dst_off + sizeof(nso0_header_t);
        if (output_offset > UINT32_MAX || source_header->segments[i].decomp_size > UINT64_MAX - output_offset) {
            fprintf(stderr, "Invalid NSO0 output segment bounds!\n");
            return 0;
        }
        output_header.segments[i].file_off = (uint32_t)output_offset;
        output_header.compressed_sizes[i] = source_header->segments[i].decomp_size;
        uint64_t end = output_offset + source_header->segments[i].decomp_size;
        if (end > output_size) output_size = end;
    }

    output_header.segments[0].align_or_total_size = 0x100;
    output_header.segments[1].align_or_total_size = 0;
    output_header.flags &= 0xF8;

    if (fseeko64(ctx->file, 0, SEEK_END) != 0) {
        fprintf(stderr, "Failed to determine NSO0 input size!\n");
        return 0;
    }
    int64_t input_length = (int64_t)ftello(ctx->file);
    if (input_length < 0) {
        fprintf(stderr, "Failed to determine NSO0 input size!\n");
        return 0;
    }

    for (unsigned int i = 0; i < 3; i++) {
        uint64_t source_size = nso_get_section_size((nso0_header_t *)source_header, i);
        uint64_t source_offset = source_header->segments[i].file_off;
        if (source_size == 0 && source_header->segments[i].decomp_size == 0) continue;
        if (source_offset < sizeof(nso0_header_t) || source_offset > (uint64_t)input_length ||
            source_size > (uint64_t)input_length - source_offset) {
            fprintf(stderr, "NSO0 segment %u lies outside the input file!\n", i);
            return 0;
        }
        if (source_size > INT_MAX || source_header->segments[i].decomp_size > INT_MAX) {
            fprintf(stderr, "NSO0 segment %u exceeds the supported decompression size!\n", i);
            return 0;
        }
    }

    FILE *output = NULL;
    if (write_output) {
        output = os_fopen(output_path->os_path, OS_MODE_WRITE);
        if (output == NULL) {
            fprintf(stderr, "Failed to open %s for uncompressed NSO0 output!\n", output_path->char_path);
            return 0;
        }
        if (fseeko64(output, (off_t)(output_size - 1), SEEK_SET) != 0 || fputc(0, output) == EOF ||
            fseeko64(output, 0, SEEK_SET) != 0 || fwrite(&output_header, 1, sizeof(output_header), output) != sizeof(output_header)) {
            fprintf(stderr, "Failed to initialize uncompressed NSO0 output!\n");
            fclose(output);
            return 0;
        }
    }

    int success = 0;
    for (unsigned int segment = 0; segment < 3; segment++) {
        uint64_t source_size = nso_get_section_size((nso0_header_t *)source_header, segment);
        uint32_t destination_size = source_header->segments[segment].decomp_size;
        if (destination_size == 0) continue;

        char *source = malloc(source_size == 0 ? 1 : (size_t)source_size);
        if (source == NULL) {
            fprintf(stderr, "Failed to allocate NSO0 input segment %u!\n", segment);
            goto cleanup;
        }
        if (fseeko64(ctx->file, source_header->segments[segment].file_off, SEEK_SET) != 0 ||
            fread(source, 1, (size_t)source_size, ctx->file) != source_size) {
            fprintf(stderr, "Failed to read NSO0 segment %u!\n", segment);
            free(source);
            goto cleanup;
        }

        char *destination = source;
        int is_compressed = (source_header->flags >> segment) & 1;
        if (is_compressed) {
            destination = malloc(destination_size);
            if (destination == NULL) {
                fprintf(stderr, "Failed to allocate decompressed NSO0 segment %u!\n", segment);
                free(source);
                goto cleanup;
            }
            int decompressed = LZ4_decompress_safe(source, destination, (int)source_size, (int)destination_size);
            if (decompressed != (int)destination_size) {
                fprintf(stderr, "Error: Failed to decompress NSO0 segment %u!\n", segment);
                free(destination);
                free(source);
                goto cleanup;
            }
        } else if (source_size != destination_size) {
            fprintf(stderr, "Uncompressed NSO0 segment %u has inconsistent sizes!\n", segment);
            free(source);
            goto cleanup;
        }

        if ((ctx->tool_ctx->action & ACTION_VERIFY) && ((source_header->flags >> (segment + 3)) & 1)) {
            unsigned char calculated_hash[0x20];
            sha256_hash_buffer(calculated_hash, destination, destination_size);
            ctx->segment_validities[segment] = memcmp(calculated_hash, source_header->section_hashes[segment], sizeof(calculated_hash)) == 0
                ? VALIDITY_VALID : VALIDITY_INVALID;
        }

        if (output != NULL &&
            (fseeko64(output, (off_t)output_header.segments[segment].file_off, SEEK_SET) != 0 ||
             fwrite(destination, 1, destination_size, output) != destination_size)) {
            fprintf(stderr, "Failed to write uncompressed NSO0 segment %u!\n", segment);
            if (destination != source) free(destination);
            free(source);
            goto cleanup;
        }

        if (destination != source) free(destination);
        free(source);
    }

    if (output != NULL && fflush(output) != 0) {
        fprintf(stderr, "Failed to flush uncompressed NSO0 output!\n");
        goto cleanup;
    }
    success = 1;

cleanup:
    if (output != NULL) fclose(output);
    return success;
}

void nso0_process(nso0_ctx_t *ctx) {
    nso0_header_t raw_header;
    if (fseeko64(ctx->file, 0, SEEK_SET) != 0 || fread(&raw_header, 1, sizeof(raw_header), ctx->file) != sizeof(raw_header)) {
        fprintf(stderr, "Failed to read NSO0 header!\n");
        exit(EXIT_FAILURE);
    }

    if (raw_header.magic != MAGIC_NSO0) {
        printf("Error: NSO0 is corrupt!\n");
        exit(EXIT_FAILURE);
    }

    ctx->header = malloc(sizeof(nso0_header_t));
    if (ctx->header == NULL) {
        fprintf(stderr, "Failed to allocate NSO0 header!\n");
        exit(EXIT_FAILURE);
    }
    memcpy(ctx->header, &raw_header, sizeof(raw_header));

    if (ctx->tool_ctx->action & (ACTION_EXTRACT | ACTION_VERIFY)) {
        if (!nso_process_segments(ctx, &raw_header)) exit(EXIT_FAILURE);
    }

    if (ctx->tool_ctx->action & ACTION_INFO) nso0_print(ctx);
}

void nso0_print(nso0_ctx_t *ctx) {
    printf("NSO0:\n");
    memdump(stdout, "    Build Id:                       ", ctx->header->build_id, 0x20);
    printf("    Sections:\n");
    if ((ctx->tool_ctx->action & ACTION_VERIFY) && ctx->segment_validities[0] != VALIDITY_UNCHECKED) {
        printf("        .text   (%s):             %08"PRIx32"-%08"PRIx32"\n", GET_VALIDITY_STR(ctx->segment_validities[0]), ctx->header->segments[0].dst_off, ctx->header->segments[0].dst_off + align(ctx->header->segments[0].decomp_size, 0x1000));
    } else {
        printf("        .text:                      %08"PRIx32"-%08"PRIx32"\n", ctx->header->segments[0].dst_off, ctx->header->segments[0].dst_off + align(ctx->header->segments[0].decomp_size, 0x1000));
    }
    if ((ctx->tool_ctx->action & ACTION_VERIFY) && ctx->segment_validities[1] != VALIDITY_UNCHECKED) {
        printf("        .rodata (%s):             %08"PRIx32"-%08"PRIx32"\n", GET_VALIDITY_STR(ctx->segment_validities[1]), ctx->header->segments[1].dst_off, ctx->header->segments[1].dst_off + align(ctx->header->segments[1].decomp_size, 0x1000));
    } else {
        printf("        .rodata:                    %08"PRIx32"-%08"PRIx32"\n", ctx->header->segments[1].dst_off, ctx->header->segments[1].dst_off + align(ctx->header->segments[1].decomp_size, 0x1000));
    }
    if ((ctx->tool_ctx->action & ACTION_VERIFY) && ctx->segment_validities[2] != VALIDITY_UNCHECKED) {
        printf("        .rwdata (%s):             %08"PRIx32"-%08"PRIx32"\n", GET_VALIDITY_STR(ctx->segment_validities[2]), ctx->header->segments[2].dst_off, ctx->header->segments[2].dst_off + ctx->header->segments[2].decomp_size);
    } else {
        printf("        .rwdata:                    %08"PRIx32"-%08"PRIx32"\n", ctx->header->segments[2].dst_off, ctx->header->segments[2].dst_off + ctx->header->segments[2].decomp_size);
    }
    printf("        .bss:                       %08"PRIx32"-%08"PRIx32"\n", ctx->header->segments[2].dst_off + ctx->header->segments[2].decomp_size, ctx->header->segments[2].dst_off + align(ctx->header->segments[2].decomp_size + ctx->header->segments[2].align_or_total_size, 0x1000));
}

void nso0_save(nso0_ctx_t *ctx) {
    (void)ctx;
}
