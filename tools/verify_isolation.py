#!/usr/bin/env python3
"""Read-only verification: original file hashes + forbidden runtime configuration."""
import hashlib
import json
import plistlib
import argparse
from pathlib import Path

lab = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--original-root", type=Path, help="原 App 所在目录；指定时必须完整匹配基线")
args = parser.parse_args()
original = args.original_root if args.original_root is not None else lab.parent
manifest = json.loads((lab / "tools/original-files.sha256.json").read_text())
original_projects = {Path(name).parts[0] for name in manifest if ".xcodeproj/" in name}
has_original = args.original_root is not None or any((original / name).is_dir() for name in original_projects)
if has_original:
    changed = [name for name, digest in manifest.items()
               if not (original / name).is_file()
               or hashlib.sha256((original / name).read_bytes()).hexdigest() != digest]
    assert not changed, "原有文件发生变化：" + repr(changed)
    print(f"PASS: 原有 {len(manifest)} 个文件保持不变。")
else:
    print("SKIP: 独立检出中没有原 App，未校验原文件；可用 --original-root 指定原目录。")
forbidden = ["cc.xiaorsz.typo-review", "111.231.22.148", "101.32.245.23", "typo-review-sync",
             "com.apple.security.application-groups", "keychain-access-groups", "ServerCredentialStore"]
sources = list((lab / "FullApp").rglob("*.swift")) + list((lab / "Core").rglob("*.swift"))
sources += [lab / "project.yml", lab / "CoachLab.xcodeproj/project.pbxproj"]
sources += list((lab / "FullApp").rglob("*.entitlements"))
sources += list((lab / "FullApp").rglob("*.plist"))
violations = [(str(p.relative_to(lab)), word) for p in sources for word in forbidden if word in p.read_text()]
assert not violations, "发现原应用的共享配置：" + repr(violations)
entitlements = plistlib.loads((lab / "FullApp/CoachLab.entitlements").read_bytes())
expected = ["iCloud.cc.xiaorsz.dictation-coach-lab"]
assert entitlements.get("com.apple.developer.icloud-container-identifiers") == expected
assert entitlements.get("com.apple.developer.ubiquity-container-identifiers") == expected
assert set(entitlements.get("com.apple.developer.icloud-services", [])) == {"CloudKit", "CloudDocuments"}
assert entitlements.get("com.apple.developer.icloud-container-environment") == "$(CLOUDKIT_ENVIRONMENT)"
assert "com.apple.security.application-groups" not in entitlements
assert "keychain-access-groups" not in entitlements
print("PASS: 实验版只声明自己的 iCloud 容器，无原 App 的容器、同步地址或共享钥匙串。")
