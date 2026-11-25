import 'dig_mode.dart';
import 'models.dart';

/// 初回セッションの1問目または2問目で使う文脈。
class FirstDigContext {
  final QaEntry? firstAnswer;
  final DigQuestion? excludedQuestion;

  const FirstDigContext({this.firstAnswer, this.excludedQuestion});

  static const axes = ['scene', 'audience', 'obstacle', 'approach', 'test'];
  static String normalize(String text) => normalizeDigText(text);
  String get substantiveAnswer => firstAnswer?.substantiveAnswer ?? '';

  bool acceptsQuestion(String question) {
    final text = normalize(question);
    return text.isNotEmpty &&
        text != normalize(firstAnswer?.question ?? '') &&
        text != normalize(excludedQuestion?.text ?? '');
  }
}
