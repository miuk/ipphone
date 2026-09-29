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

マイルストーン6まで完了しています。

- PJSIP EndpointとUDPトランスポートの初期化・停止
- SIP、アカウント、メディア、TLS設定と入力検証
- UserDefaultsおよびKeychainへの設定保存
- OSLogとアプリ内ログ表示
- UDPによるREGISTER、Digest認証、登録解除、自動更新
- UDPによる発着信、応答、拒否、CANCEL、BYE
- PCMU（8 kHz、mono）によるRTP音声の送受信とCore Audio入出力
- 音声デバイス指定、マイクミュート、RTP送受信・損失・ジッター表示
- telephone-eventおよびin-band DTMF送信
- telephone-event非対応時のin-band自動フォールバックと通話中キーパッド

次のマイルストーンはTCP／TLSです。
