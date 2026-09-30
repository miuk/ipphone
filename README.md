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

デバッグ用の `.build/debug/IPPhoneApp` にもマイク利用理由を埋め込んでいます。
ローカルIPが「Automatic」の場合は、SIPサーバーへの経路で使うIPを
SIPヘッダーとSDPに通知し、RTPソケットもそのIPにバインドします。
初回通話時に macOS のマイク許可を求められたら許可してください。通話中は
「Media」が `PCMU/8000 send/receive` となり、「RTP」の TX 件数が
無音中も増えることを確認できます。Media に失敗が表示された場合は、
その内容と通話相手の SDP を確認してください。

## ローカル配布用ビルド

```bash
scripts/package_app.sh
```

`.build/distribution`へApple Silicon向けの`IPPhone.app`、受け渡し用ZIP、
クラッシュ解析用dSYMを生成します。OpenSSLの実行時ライブラリと第三者
ライセンス、マイク利用目的を同梱します。Developer ID署名とAppleの公証は
行わず、ローカル実行に必要なアドホック署名だけを付与します。

マイルストーン9まで完了しています。

- PJSIP EndpointとUDPトランスポートの初期化・停止
- SIP、アカウント、メディア、TLS設定と入力検証
- SIPヘッダ用ローカルIPの自動選択／インターフェース別選択（IPv4・IPv6）
- UserDefaultsおよびKeychainへの設定保存
- OSLogとアプリ内ログ表示
- UDPによるREGISTER、Digest認証、登録解除、自動更新
- UDPによる発着信、応答、拒否、CANCEL、BYE
- PCMU（8 kHz、mono）によるRTP音声の送受信とCore Audio入出力
- 音声デバイス指定、マイクミュート、RTP送受信・損失・ジッター表示
- telephone-eventおよびin-band DTMF送信
- telephone-event非対応時のin-band自動フォールバックと通話中キーパッド
- UDP、TCP、TLSによるREGISTER・発着信経路
- TLS 1.2/1.3、サーバー証明書検証設定、`sip:`／`sips:`切替
- 認証情報を含まないSIP送受信要約ログとログエクスポート
- 秘密情報のマスキング、CANCEL競合を含むエラー・状態遷移テスト
- Apple Silicon向けローカル配布用`.app`、ZIP、dSYM生成

計画した全マイルストーンを完了しています。

複数のローカルIPがある場合は、Settings → SIP Server →
「Local IP for SIP headers」で使用するIPを選び、Saveで保存してください。
Via・ContactヘッダとSDPに選択したIPを使用します。Automaticでは従来どおり
自動選択します。起動中に変更した場合は、Phone画面でStopしてから再起動してください。
IP一覧は「Refresh local IP addresses」で更新できます。利用できなくなった選択済みIPは
unavailableと表示し、起動時にエラーにします。IPv6リンクローカルアドレスは一覧から除外します。
