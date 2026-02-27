# SoundBridge（声桥）

SoundBridge 是一个面向听障老人家庭沟通场景的 Apple 生态应用。  
它把家人的自然说话实时转换为老人可读的大字信息，减少“听不见”带来的重复沟通与照护焦虑。

## 项目概述

- iPhone 端：实时语音识别（普通话/粤语），连续发送文本
- iPad 端：大字流式显示、文本清洁、状态可视化
- 设备互联：基于 MultipeerConnectivity 的低延迟近场协作
- 端侧 AI：标点与清洁能力用于提升可读性并保留关键事实（时间、药量、地点等）

## 技术架构

- `SoundBridge-iPhone/`：说话侧（采集、识别、发送）
- `Shared/Services/MPCService.swift`：iPhone 与 iPad 间实时通信
- `SoundBridge-iPad/`：老人侧（接收、清洁、展示）
- `Shared/Utils/Constants.swift`：跨端常量与配置
- `SoundBridge.xcodeproj/`：Xcode 工程

## 快速开始

环境要求：

- Xcode（建议 16+）
- iOS SDK（iPhone + iPad）
- `xcodegen`（仅在 `project.yml` 修改后需要）

如修改过 `project.yml`：

```bash
xcodegen generate
```

构建 iPhone Target：

```bash
xcodebuild -project SoundBridge.xcodeproj -scheme SoundBridge-iPhone -destination 'generic/platform=iOS' -derivedDataPath ./build/DerivedData build
```

构建 iPad Target：

```bash
xcodebuild -project SoundBridge.xcodeproj -scheme SoundBridge-iPad -destination 'generic/platform=iOS' -derivedDataPath ./build/DerivedData build
```

## 仓库内容

- `Shared/`：共享模型、服务、工具
- `SoundBridge-iPhone/`：iPhone 应用源码
- `SoundBridge-iPad/`：iPad 应用源码
- `SoundBridge.xcodeproj/`：项目工程
- `scripts/`：评测与辅助脚本
- `project.yml`：XcodeGen 配置

## 未纳入仓库的本地大文件

为保证仓库可克隆、可协作，以下内容未上传：

- `build/`
- `models/`
- `*.data`
- 用户本地 Xcode 状态（`xcuserdata`）
