# 公開リポジトリのbranch運用

mainを公開の集約幹とする。公開時は、検証済みの開発成果の木を、現在の公開mainの先端を親とする
1commitに集約し、mainをfast-forwardで更新する。親が常に公開mainの先端なので、強制pushは要らない。
生の作業履歴は公開しない。

公開originが持つbranchは、main(集約幹)と、上流へのPR用branchと、旧mainの退避だけである。
developはローカルの作業幹であり、公開originには置かない。developは集約の後も作業を続け、mainへmergeしない。
集約前の履歴を持つbranchと旧feature branchは、ローカルの保管用branchとして残し、upstream設定を持たせず、
公開originへpushしない。

公開originへのpushとbranchの削除は、1回ごとに殿の承認を得る。承認の対象は、載せる集約commitや
削除するbranchを具体的に特定したものとする。

上流の更新は、developでmergeしてから次の集約に含める。mainで直接mergeしない。

上流へのPRは、upstream/mainを基点とする専用branchから出す。開発中の履歴をそのまま載せず、
必要な変更だけを新しいcommitにする。

## 公開前の検査

公開は専用の道具を通して行う。mainの集約公開では、道具は送信の前に、次のことを検査する。

- 載せる木が、検証済みの開発成果の木と一致すること
- 公開mainからfast-forwardで進み、我方の新規commitが集約の1つだけであること(上流由来の祖先は数えない)
- 生の作業履歴のcommitを含まないこと
- 禁則語の走査が0件であること
- 承認された集約commitと一致すること

上流同期を含む集約では、上流mainも親に含める。PR用branchの公開では、上流main基点であること、
公開mainを含まないこと、必要な変更の走査が0件であること、生の作業履歴を含まないこと、
承認された先端との一致を確認する。上記の集約の木・1commitの条件はPRには適用しない。

pre-push hookは、送り先が公開originでないpush、tagのpush、mainの削除、確認の手順を経ていない
branchの削除、developや保管用branchを名前で指定したpush、生の作業履歴を含むpush、上の道具の
検査を経ていないpushを拒否する。引数なしの`git push`は、gitの設定(`push.default=nothing`)でも
拒否される。hookが失われるとgitは黙って素通しにするため、公開の前に道具がhookの設置を確認する。

hookと設定は、手癖や送り先の取り違えを止めるためのものであり、hookを意図的に外す操作までは止めない。
