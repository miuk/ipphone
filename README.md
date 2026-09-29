# IP Phone Test Client

macOS 27向けのSIPテストクライアントです。仕様と計画は
[`initial_spec.md`](initial_spec.md) および
[`development_plan.md`](development_plan.md) を参照してください。

## 開発環境

- Xcode 27.0
- Swift 6.4
- Apple Silicon
- PJSIP 2.17（Homebrewの`pjproject`）

```bash
brew install pjproject
swift test
swift run IPPhoneApp
```

現在はマイルストーン1として、PJSIP EndpointとUDPトランスポートの
初期化・停止までを実装しています。
