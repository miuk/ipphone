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
初回通話時に macOS のマイク許可を求められたら許可してください。

## 画面構成

サイドバーから次の4画面を切り替えます。

| 画面 | 表示・操作 |
| --- | --- |
| Phone | PJSIPバージョン、Endpoint状態、Local SIP IP、Server、Address of Record、Registration状態。Endpointの起動・停止、登録・登録解除。 |
| Calls | Call／Media状態、着番号入力、Call／Hang Up／Mute（ミュート中はUnmute）。着信時のAnswer／Reject。Mediaが有効な間のRTP統計とDTMFダイヤルパッド。 |
| Settings | SIP Server、Account、Media、TLSの設定とSave。入力検証結果と保存エラーの表示。 |
| Logs | アプリ内ログの閲覧、Copyによるクリップボードへのエクスポート、Clearによる消去。 |

画面を切り替えても入力した着番号、DTMF送信結果、通話状態は保持されます。

## 基本操作

1. **Settings**でSIPサーバー、Transport、User ID、Password、Phone numberなどを入力し、**Save**で保存します。SIP domainが空欄の場合はサーバーホストを使用します。
2. **Phone**で**Start UDP/TCP/TLS endpoint**を押してEndpointを起動し、**Register**で登録します。Endpointが停止している場合、Registerでも自動的に起動します。
3. **Calls**で「Destination number or SIP URI」に着番号または完全な `sip:`／`sips:` URIを入力し、**Call**またはEnterで発信します。Callでも停止中のEndpointは自動的に起動します。
4. 着信時は**Calls**の**Answer**で応答、**Reject**で拒否します。発信中・通話中は**Hang Up**で切断します。通話処理中は着番号入力が無効になります。
5. Mediaが有効になると**Mute／Unmute**、RTP統計、DTMFダイヤルパッドを利用できます。DTMF方式は**Settings → Media → DTMF**で選択します。telephone-eventが相手側で利用できない場合はin-bandへ自動的にフォールバックし、送信結果を表示します。
6. **Phone**の**Unregister**で登録解除、**Stop**でEndpointを停止します。

通話中は**Calls**の「Media」が `PCMU/8000 send/receive` となり、
「RTP」にTX／RX／Lostのパケット数とJitter（μs）を表示します。
無音中もTX件数が増えることを確認できます。Mediaに失敗が表示された場合は、
その内容と通話相手のSDP、および**Logs**を確認してください。

### ローカルIPの選択

複数のローカルIPがある場合は、**Settings → SIP Server → Local IP for SIP headers**で
使用するIPを選び、**Save**で保存してください。Via・Contactヘッダー、SDP、
RTPソケットに選択したIPを使用します。**Automatic**ではSIPサーバーへの経路で使うIPを
自動選択します。

IP一覧は**Refresh local IP addresses**で更新できます。利用できなくなった選択済みIPは
`unavailable`と表示し、起動時にエラーにします。IPv6リンクローカルアドレスは一覧から除外します。
TransportまたはローカルIPを起動中に変更するとPhone／Callsに再起動を促す表示が出ます。
**Phone**で**Stop**してからEndpointを再起動してください。

## ローカル配布用ビルド

```bash
scripts/package_app.sh
```

`.build/distribution`へApple Silicon向けの`IPPhone.app`、受け渡し用ZIP、
クラッシュ解析用dSYMを生成します。OpenSSLの実行時ライブラリと第三者
ライセンス、マイク利用目的を同梱します。Developer ID署名とAppleの公証は
行わず、ローカル実行に必要なアドホック署名だけを付与します。

## 実装済み機能

計画した全9マイルストーンを完了しています。

- Phone／Calls／Settings／Logsの画面分割と、画面切替時の着番号・通話状態の保持
- PJSIP EndpointとUDP／TCP／TLSトランスポートの初期化・停止
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
