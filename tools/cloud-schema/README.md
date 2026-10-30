# 实验版 CloudKit 结构部署文件

容器仅限 `iCloud.cc.xiaorsz.dictation-coach-lab`。这些文件只描述结构，不包含题库、孩子姓名、对错记录或任何凭据。生成器没有网络、CloudKit 写入或部署能力。

- `CoachLab.native-model.json`：`CloudSchemaExportTests` 通过公开的 `NSManagedObjectModel.makeManagedObjectModel(for:)` 从本实验版的 17 个实际模型导出，包含 170 个原生属性。
- `Users.original.ckdb`：2026-10-30 从该容器 CloudKit Console 的 Production 导出并提供的 356 字节基准，只有系统 `Users` 类型。
- `CoachLab.ckdb`：基准加上 17 个应用记录类型；包含 264 个应用／Core Data 字段和 102 个系统字段。系统 `Users` 定义及其授权保持不变；新类型不授予公共库访问权限。本 App 使用私有数据库。
- `CoachLab.manifest.json`：输入、输出的 SHA-256 和具体字段表。

此文件使用**实际原生模型加 Apple 官方字段映射**生成，不是 `initializeCloudKitSchema(.printSchema)` 的输出。当前模型无关系、加密、转换器或未知属性类型；遇到这些特性时生成器会拒绝继续，要求用 Apple 原生初始化器核实。字符串同时生成对应的 `_ckAsset` 溢出字段；UUID 映射为字符串，不额外生成资产字段。

在实验版目录运行：

```sh
python3 tools/generate_cloud_schema.py \
  --model-json tools/cloud-schema/CoachLab.native-model.json \
  --users-schema tools/cloud-schema/Users.original.ckdb \
  --output tools/cloud-schema/CoachLab.ckdb
python3 tools/test_generate_cloud_schema.py
```

使用时先核对原生导出与当前 App 模型相同，再通过该容器的 Development 导入验证，复核 Production 部署差异后才部署。不要重置环境、删除区域或清空记录。部署结构不会复制开发库的用户数据；生产同步是否恢复仍需查看实际设备的 setup/export/import 事件。

2026-10-30 部署记录：用户明确授权后，通过 Apple CloudKit Console 上传本文件，校验通过，导入 Development 并部署 Production。部署差异仅新增 17 个应用类型与 17 个记录 ID 查询索引，无角色变更或删除项。生产环境已读回全部类型及 AI 清单新增字段；原 Users 未改动，新类型仍无公共库授权。此次不上传或编辑学习记录，不操作原 App 容器，不上传新 TestFlight 包。结构 SHA256 和证据路径见 `deployment-2026-10-30.json`。实际设备同步仍待验证。

Apple 依据：

- [字段及溢出资产映射](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data)
- [Schema DSL 与权限语义](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
- [Apple 仓库中的 Core Data schema 与系统字段示例](https://github.com/apple-aiml-research/ml-comlet/blob/main/ckschema.ckdb)
- [原生 schema 初始化器](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/initializecloudkitschema(options:))
