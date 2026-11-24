import 'models.dart';

/// 名前決めアシストのローカル候補生成（v0.2 項目6）。
/// AIが使えないときでも必ず3件返すための簡易ルール。
/// 品質は最低限でよい（表示のみで、名前を勝手に変えることはしない）。
class LocalNameCandidates {
  static List<String> generate({required String title, PlanMemo? memo}) {
    // タイトルの語を土台にする（記号・空白を除き、長すぎれば先頭を取る）。
    var base = title.replaceAll(RegExp(r'[\s　・/／]'), '');
    if (base.isEmpty) base = 'アプリ';
    final short = base.length > 6 ? base.substring(0, 6) : base;

    // What の最初の語（読点・空白まで）も候補の材料にする。
    var whatWord = '';
    if (memo != null) {
      final w = memo.what.replaceAll('「', '').replaceAll('」', '');
      final m = RegExp(r'^[^、。\s　]+').firstMatch(w);
      if (m != null) whatWord = m.group(0)!;
      if (whatWord.length > 6) whatWord = whatWord.substring(0, 6);
    }

    final raw = <String>[
      short,
      whatWord.isNotEmpty && whatWord != short ? whatWord : '$shortメモ',
      '$shortノート',
      '$shortログ',
    ];
    // 重複を避けながら必ず3件にする。
    final result = <String>[];
    for (final c in raw) {
      if (result.length >= 3) break;
      var candidate = c;
      var n = 2;
      while (result.contains(candidate)) {
        candidate = '$c$n';
        n++;
      }
      result.add(candidate);
    }
    return result;
  }
}
