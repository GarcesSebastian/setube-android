import 'package:flutter_test/flutter_test.dart';
import 'package:setube/core/errors.dart';

void main() {
  test('clasifica la salida de yt-dlp', () {
    expect(classifyYtdlpError('ERROR: [youtube] x: Sign in to confirm you’re not a bot.'), ErrCode.upstreamBlocked);
    expect(classifyYtdlpError('ERROR: [youtube] x: Private video. Sign in'), ErrCode.privateVideo);
    expect(classifyYtdlpError('Sign in to confirm your age'), ErrCode.ageRestricted);
    expect(classifyYtdlpError('ERROR: Video unavailable'), ErrCode.videoUnavailable);
    expect(classifyYtdlpError('The uploader has not made this video available in your country'), ErrCode.videoUnavailable);
    expect(classifyYtdlpError('ERROR: unable to download video data: HTTP Error 403: Forbidden'), ErrCode.upstreamForbidden);
    expect(classifyYtdlpError('Requested format is not available'), ErrCode.formatUnavailable);
    expect(classifyYtdlpError('algo raro'), ErrCode.upstreamError);
    expect(classifyYtdlpError('', exitCode: 0), ErrCode.unknown);
  });

  test('errores definitivos', () {
    expect(isDefinitive(ErrCode.privateVideo), isTrue);
    expect(isDefinitive(ErrCode.upstreamError), isFalse);
    expect(isDefinitive(ErrCode.upstreamBlocked), isFalse);
  });
}
