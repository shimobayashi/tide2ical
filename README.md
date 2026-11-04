# tide2ical

[日本沿岸 736 港の潮汐表 \- tide736\.net](https://tide736.net/)の API を叩いて日本の潮汐表を iCal 形式で出力するスクリプトです。

## Usage

```
bundle install
bundle exec ruby tide2ical.rb --pc 28 --hc 9 --date "2022-02-01" --repeat 3 > tide.ics
```

これで 90 日分の兵庫県明石の潮汐表が tide.ics に出力されます。

- pc や hc に何を指定するかは[日本沿岸 736 港の潮汐表 \- tide736\.net](https://tide736.net/)を参照してください
- repeat は 30 日分を何回繰り返して取得したいか指定してください


## AWS での自動更新

EventBridge Scheduler が30日ごとに Lambda を呼び、当日から90日分のカレンダーを生成します。
全期間の取得と検査に成功した場合だけ、S3 の同じファイルを上書きします。
CloudFront が固定の HTTPS URL で配信し、Google カレンダーからその URL を購読します。

- S3 は非公開にし、CloudFront にカレンダーの読み取りだけを許可します。
- 予定の UID は再生成しても同じになり、時刻は実行環境に依存しない UTC で出力します。
- 過去の予定は蓄積しません。前の生成で含まれていた過去分は、次の更新時にファイルから外れます。
- API の取得や SSM の読み取りに失敗した場合は、前のファイルを残します。
- Scheduler の呼び出し失敗と Lambda の処理失敗は、それぞれ最大2回再試行します。
- Lambda の成功・再試行後の失敗を SNS のメールで通知します。Scheduler から Lambda に渡せなかったイベントは、専用の SQS キューに14日間保存します。
- 固定費を抑えるため、VPC、NAT Gateway、カスタムメトリクス、CloudWatch アラームは作りません。スケジュール自体の無効化や通知の配信失敗は自動検知しません。約30日ごとの成功通知が届かない場合は、Scheduler と SQS の失敗キューを確認してください。
- CloudFront のキャッシュは最大1時間です。Google 側の取得タイミングは制御できません。

### 非公開にする設定

このリポジトリは公開されています。
実際の地域、S3 バケット名、アカウント ID、配信 URL、メールアドレスをコミット・PR・共有ログに含めないでください。
設定例はダミーです。

地域の値は Terraform に渡さず、Lambda が SSM Parameter Store から実行時に読みます。
Terraform は SSM の値を作成も取得もしないため、地域の値は Terraform の状態に入りません。
S3 バケット名は AWS プロバイダーが一意な末尾を付けて生成します。
配信 URL、バケット名、失敗キューの URL は Terraform の通常の出力では隠します。
ただし、実際のリソース名や通知先は状態ファイルや plan に含まれるので、それらも非公開で管理してください。

配信するカレンダー自体はログインなしで読め、港名を含みます。
URL を知る人は内容を取得できるため、配信 URL を公開リポジトリなどへ掲載しないでください。

### 準備

1. `mise install` で Ruby と Terraform を用意します。
2. `bundle install` で開発・テスト用の依存を用意します。
3. AWS の対象アカウントとリージョンに、SSM の**標準 String パラメータ**を作成します。初期のパラメータ名は `/tide2ical/location` です。値は `prefecture_code` と `harbor_code` をキーに持つ JSON とし、[提供元の港一覧](https://tide736.net/)で選んだ実際の数値を入れてください。値をリポジトリ内のファイルに保存する必要はありません。SecureString はこの構成では扱いません。
4. Terraform 状態用の S3 バケットを用意します。既存のバケットを使う場合は、このプロジェクト専用のキーを選びます。新しく作る場合は下の「状態保存用バケットの作成」に進んでください。`terraform/backend.hcl.example` を基に、無視対象の `terraform/backend.hcl` に非公開の実際の保存先を設定します。既存プロジェクトと同じ状態のキーを使わないでください。
5. `terraform/terraform.tfvars.example` を基に、無視対象の `terraform/terraform.tfvars` を作ります。通知先を設定し、SSM のパラメータ名を変えた場合はここにも反映します。地域の値や実際のバケット名は書きません。

認証は AWS CLI のプロファイルなどで用意してください。
認証情報を Terraform やソースコードに書かないでください。

### 状態保存用バケットの作成

専用のバケットを新しく作る場合だけ実行します。
初回はローカルに状態を保存し、バケットができてから状態も S3 に移します。

```sh
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap plan
terraform -chdir=terraform/bootstrap apply
```

この構成は、非公開・暗号化・バージョン管理を設定したバケットを作り、HTTP でのアクセスを拒否します。
状態保存先を誤って削除しないよう `prevent_destroy` を設定しています。
バケット名は `terraform -chdir=terraform/bootstrap output -raw state_bucket` で手元だけで確認してください。

`terraform/backend.hcl.example` を基に、アプリ用の `terraform/backend.hcl` と、初期化用の `terraform/bootstrap/backend.hcl` を作ります。
両方に同じバケットを指定し、状態のキーをそれぞれ `tide2ical/application.tfstate`、`tide2ical/bootstrap.tfstate` に分けてください。
その後、次のコマンドで初期化用の状態を S3 に移します。

```sh
cp terraform/bootstrap/backend.tf.example terraform/bootstrap/backend_override.tf
terraform -chdir=terraform/bootstrap init -migrate-state -backend-config=backend.hcl
```

移行先のキーと移行内容を確認して承認してください。
`backend.hcl`、`backend_override.tf`、ローカルの状態ファイルはコミット対象外です。
再実行する場合は移行後のバックエンドを使い、状態を新しく作り直さないでください。

[S3 バックエンドと状態のロック](https://developer.hashicorp.com/terraform/language/backend/s3)・[prevent_destroy の仕様](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy)

### 配布物の作成と適用

```sh
ruby scripts/package_lambda.rb
terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

Ruby 3.4 で配布物を作ります。
Terraform が配布用ディレクトリを ZIP にします。
カレンダーの依存ライブラリだけを同梱し、AWS SDK は [Lambda の Ruby ランタイムに含まれるもの](https://docs.aws.amazon.com/lambda/latest/dg/ruby-package.html)を使います。
依存ライブラリやコードを変えたら、配布物の作成からやり直してください。

Terraform は SSM の値を確認しないので、適用前に AWS 側でパラメータを作ってください。
適用後、SNS から届くメールで購読を承認します。
`rate(30 days)` の最初の実行を待たず、次の非同期呼び出しで初回生成できます。

```sh
aws lambda invoke --region ap-northeast-1 \
  --function-name "$(terraform -chdir=terraform output -raw function_name)" \
  --invocation-type Event --cli-binary-format raw-in-base64-out \
  --payload '{}' /tmp/tide2ical-invoke.json
```

呼び出しの受付は生成の成功を意味しません。
成功通知を確認してください。
失敗通知の場合は、SSM の値や API への接続を確認してから同じコマンドで再実行できます。
180秒で処理を打ち切り、ログは14日で削除します。

CloudFront の配信準備と初回生成が終わったら、手元だけで次の出力を確認します。
出力した URL は共有ログや PR に貼らないでください。

```sh
terraform -chdir=terraform output -raw calendar_url
```

### Google カレンダーに登録

パソコンの Google カレンダーで「他のカレンダー → URL で追加」を開き、配信 URL を一度登録します。
ファイルのインポートでは自動更新しません。
既に手動で取り込んだ予定は別に残るので、重複する予定や古い専用カレンダーは登録状況を見て整理してください。

[Google の URL 登録手順](https://support.google.com/calendar/answer/37100?hl=ja)

### 検証

```sh
TZ=UTC bundle exec ruby test/calendar_test.rb
ruby scripts/package_lambda.rb
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -lockfile=readonly
terraform -chdir=terraform validate
terraform -chdir=terraform test
terraform -chdir=terraform/bootstrap init -backend=false -lockfile=readonly
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/bootstrap test
```

テストには模擬 API・AWS の応答を使い、認証や実際の地域の設定は不要です。
Terraform のテストは実際の AWS リソースを作りません。
既にバックエンドを設定した作業ディレクトリでは、構成検査用に別の作業コピーを使うか、初期化済みのバックエンドを使ってください。

### 費用

生成は30日ごとに1回、通常は潮汐 API を3回呼びます。
SSM は標準パラメータと通常のスループットを使います。
Lambda・Scheduler・SNS などは無料枠が他のプロジェクトと共有されるため、この構成が必ず無料になるとは限りません。
S3 の保存とリクエスト、CloudFront の配信、ログ、Terraform の状態保存にも料金がかかる場合があります。
成功通知は月に約1回で、アラームを常時動かす費用はありません。

- [Scheduler と Lambda の定期実行](https://docs.aws.amazon.com/lambda/latest/dg/with-eventbridge-scheduler.html)
- [非同期呼び出しの再試行](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html)
- [Lambda の結果通知](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-retain-records.html)
- [CloudFront から S3 へのアクセス制限](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)
- [SSM Parameter Store の料金](https://aws.amazon.com/systems-manager/pricing/)
