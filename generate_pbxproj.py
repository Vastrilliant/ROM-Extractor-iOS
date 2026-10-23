#!/usr/bin/env python3
"""Regenerates RuinaExtractor.xcodeproj/project.pbxproj from the files on disk."""
import hashlib, os

ROOT = os.path.dirname(os.path.abspath(__file__))
NAME = "RuinaExtractor"

def uid(s): return hashlib.md5(s.encode()).hexdigest()[:24].upper()

swift = sorted(f for f in os.listdir(f"{ROOT}/RuinaExtractor") if f.endswith(".swift"))
c_main = sorted(f for f in os.listdir(f"{ROOT}/Hactool") if f.endswith(".c"))
c_mbed = sorted(f for f in os.listdir(f"{ROOT}/Hactool/mbedtls/library") if f.endswith(".c"))
h_main = sorted(f for f in os.listdir(f"{ROOT}/Hactool") if f.endswith(".h"))

refs, builds, groups = [], [], {}
def add_file(path, kind, group, compile=False):
    r = uid("ref:" + path)
    refs.append(f'\t\t{r} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; name = {os.path.basename(path)}; path = {os.path.basename(path)}; sourceTree = "<group>"; }};')
    groups.setdefault(group, []).append((r, os.path.basename(path)))
    if compile:
        b = uid("build:" + path)
        builds.append((b, r, os.path.basename(path)))

for f in swift: add_file(f"RuinaExtractor/{f}", "sourcecode.swift", "app", True)
add_file("RuinaExtractor/RuinaExtractor-Bridging-Header.h", "sourcecode.c.h", "app")
add_file("RuinaExtractor/Info.plist", "text.plist.xml", "app")
for f in c_main: add_file(f"Hactool/{f}", "sourcecode.c.c", "hactool", True)
for f in h_main: add_file(f"Hactool/{f}", "sourcecode.c.h", "hactool")
for f in c_mbed: add_file(f"Hactool/mbedtls/library/{f}", "sourcecode.c.c", "mbed", True)

product = uid("product")
g_app, g_hac, g_mbed, g_prod, g_main = uid("g_app"), uid("g_hac"), uid("g_mbed"), uid("g_prod"), uid("g_main")
proj, target, src_phase, fw_phase, res_phase = uid("proj"), uid("target"), uid("srcphase"), uid("fwphase"), uid("resphase")
cl_proj, cl_target = uid("cl_proj"), uid("cl_target")
dbg_p, rel_p, dbg_t, rel_t = uid("dbg_p"), uid("rel_p"), uid("dbg_t"), uid("rel_t")

def children(items): return ",\n".join(f"\t\t\t\t{r} /* {n} */" for r, n in items)

out = []
out.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")
out.append("/* Begin PBXBuildFile section */")
for b, r, n in builds:
    out.append(f"\t\t{b} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {r} /* {n} */; }};")
out.append("/* End PBXBuildFile section */\n")
out.append("/* Begin PBXFileReference section */")
out += refs
out.append(f'\t\t{product} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
out.append("/* End PBXFileReference section */\n")
out.append("/* Begin PBXFrameworksBuildPhase section */")
out.append(f"\t\t{fw_phase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXFrameworksBuildPhase section */\n")
out.append("/* Begin PBXGroup section */")
out.append(f"\t\t{g_main} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{g_app} /* {NAME} */,\n\t\t\t\t{g_hac} /* Hactool */,\n\t\t\t\t{g_prod} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append(f"\t\t{g_app} /* {NAME} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children(groups['app'])}\n\t\t\t);\n\t\t\tpath = {NAME};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
hk = children(groups['hactool']) + f",\n\t\t\t\t{g_mbed} /* mbedtls */"
out.append(f"\t\t{g_hac} /* Hactool */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{hk}\n\t\t\t);\n\t\t\tpath = Hactool;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append(f"\t\t{g_mbed} /* mbedtls */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children(groups['mbed'])}\n\t\t\t);\n\t\t\tpath = mbedtls/library;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append(f"\t\t{g_prod} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{product} /* {NAME}.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
out.append("/* End PBXGroup section */\n")
out.append("/* Begin PBXNativeTarget section */")
out.append(f"\t\t{target} /* {NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {cl_target};\n\t\t\tbuildPhases = (\n\t\t\t\t{src_phase} /* Sources */,\n\t\t\t\t{fw_phase} /* Frameworks */,\n\t\t\t\t{res_phase} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {NAME};\n\t\t\tproductName = {NAME};\n\t\t\tproductReference = {product} /* {NAME}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};")
out.append("/* End PBXNativeTarget section */\n")
out.append("/* Begin PBXProject section */")
out.append(f"\t\t{proj} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {cl_proj};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {g_main};\n\t\t\tproductRefGroup = {g_prod} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{target} /* {NAME} */,\n\t\t\t);\n\t\t}};")
out.append("/* End PBXProject section */\n")
out.append("/* Begin PBXResourcesBuildPhase section */")
out.append(f"\t\t{res_phase} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXResourcesBuildPhase section */\n")
out.append("/* Begin PBXSourcesBuildPhase section */")
files_list = ",\n".join(f"\t\t\t\t{b} /* {n} in Sources */" for b, r, n in builds)
out.append(f"\t\t{src_phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files_list}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};")
out.append("/* End PBXSourcesBuildPhase section */\n")

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu11",
    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
}
def settings(d, indent="\t\t\t\t"):
    return "\n".join(f'{indent}{k} = {v if v.replace("_","").isalnum() else chr(34)+v+chr(34)};' for k, v in d.items())
proj_dbg = dict(common, DEBUG_INFORMATION_FORMAT="dwarf", ONLY_ACTIVE_ARCH="YES", GCC_OPTIMIZATION_LEVEL="0", SWIFT_OPTIMIZATION_LEVEL="-Onone", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
proj_rel = dict(common, DEBUG_INFORMATION_FORMAT="dwarf-with-dsym", SWIFT_COMPILATION_MODE="wholemodule", VALIDATE_PRODUCT="YES")
tgt = {
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "RuinaExtractor/Info.plist",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.RuinaExtractor",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_OBJC_BRIDGING_HEADER": "RuinaExtractor/RuinaExtractor-Bridging-Header.h",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "HEADER_SEARCH_PATHS": "$(SRCROOT)/Hactool $(SRCROOT)/Hactool/mbedtls/include",
    "GCC_WARN_INHIBIT_ALL_WARNINGS": "YES",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
}
out.append("/* Begin XCBuildConfiguration section */")
for i, n, d in [(dbg_p, "Debug", proj_dbg), (rel_p, "Release", proj_rel)]:
    out.append(f"\t\t{i} /* {n} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(d)}\n\t\t\t}};\n\t\t\tname = {n};\n\t\t}};")
for i, n in [(dbg_t, "Debug"), (rel_t, "Release")]:
    out.append(f"\t\t{i} /* {n} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(tgt)}\n\t\t\t}};\n\t\t\tname = {n};\n\t\t}};")
out.append("/* End XCBuildConfiguration section */\n")
out.append("/* Begin XCConfigurationList section */")
out.append(f"\t\t{cl_proj} /* Build configuration list for PBXProject */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{dbg_p} /* Debug */,\n\t\t\t\t{rel_p} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
out.append(f"\t\t{cl_target} /* Build configuration list for PBXNativeTarget */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{dbg_t} /* Debug */,\n\t\t\t\t{rel_t} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
out.append("/* End XCConfigurationList section */")
out.append(f"\t}};\n\trootObject = {proj} /* Project object */;\n}}\n")

d = f"{ROOT}/{NAME}.xcodeproj"
os.makedirs(d, exist_ok=True)
open(f"{d}/project.pbxproj", "w").write("\n".join(out))
print("wrote", d, len(builds), "sources")
