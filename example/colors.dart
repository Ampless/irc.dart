import 'package:irc/client.dart';

void main() {
  print("Colors: ${Color.allColors().keys.join(", ")}");
  Color.allColors().forEach((a, b) {
    print('- $a: $b');
  });
}
