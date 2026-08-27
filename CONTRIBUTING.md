# 为 Transnap 贡献代码

感谢你愿意改进 Transnap。为了让问题和代码审查保持高效，请先阅读以下约定。

## 开发环境

- macOS 13 或更高版本
- Swift 5.10（项目使用的编程语言版本）或更高版本
- Apple Command Line Tools（苹果命令行开发工具）

```bash
swift --version
swift build
./scripts/test.sh
```

项目不依赖第三方 Swift 软件包，也不需要在仓库中创建包含密钥的配置文件。

## 提交问题

提交缺陷时，请尽量包含：

- macOS 版本和 Mac 芯片类型
- Transnap 版本
- 出现问题的应用
- 可复现步骤、预期行为和实际行为
- 已脱敏的截图或日志

不要提交接口密钥、内部接口地址、私人翻译内容或其他敏感信息。

## Pull Request

1. 每个 Pull Request（代码合并请求）只解决一个明确问题。
2. 尽量保持原生 AppKit 风格，不引入不必要的第三方依赖。
3. 行为变更需要补充 `SelfTests.swift` 中的无网络测试。
4. 提交前执行：

```bash
swift build
./scripts/test.sh
./scripts/build-app.sh release
codesign --verify --deep --strict dist/Transnap.app
```

5. 界面改动请附上修改前后的截图。

## 代码组织

- `App/`：应用生命周期和入口。
- `Core/`：与界面无关的配置、读取、网络和持久化逻辑。
- `UI/`：窗口、浮层和控件。
- `Support/`：开发和自测辅助代码。

新增代码应放入职责最接近的目录，避免继续扩大已有的大型控制器。
