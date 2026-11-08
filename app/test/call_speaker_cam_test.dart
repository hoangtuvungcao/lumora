// Calls: the speaker button follows the camera (a voice call turned into a video call).
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('answered voice call: camera on → loudspeaker + video layout; off → earpiece', () async {
    final store = CallStore(MockLumoraApi());
    store.onCall({'call_id': 'c1', 'state': 'incoming', 'conv': 'd:alice', 'peer': 'alice', 'video': false});
    expect(store.speaker, isFalse);
    store.onCall({'call_id': 'c1', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice', 'video': false});
    expect(store.speaker, isFalse);
    await store.toggle(cam: true);
    expect(store.speaker, isTrue, reason: 'camera on: loudspeaker');
    expect(store.call!.video, isTrue);
    // a later call event from the core (video: false) keeps it a video call
    store.onCall({'call_id': 'c1', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice', 'video': false});
    expect(store.call!.video, isTrue);
    expect(store.speaker, isTrue);
    await store.toggle(cam: false);
    expect(store.speaker, isFalse, reason: 'camera off: back to the earpiece');
  });

  test('their camera off: accountCamOff (the 1:1 stage shows their avatar)', () {
    final store = CallStore(MockLumoraApi());
    store.onCall({'call_id': 'c1', 'state': 'active', 'conv': 'd:alice', 'peer': 'alice', 'video': true, 'participants': ['alice']});
    expect(store.accountCamOff('alice'), isFalse);
    store.onCallPeer({'call_id': 'c1', 'peer': 'alice', 'mic': true, 'cam': false});
    expect(store.accountCamOff('alice'), isTrue);
    store.onCallPeer({'call_id': 'c1', 'peer': 'alice', 'mic': true, 'cam': true});
    expect(store.accountCamOff('alice'), isFalse);
  });
}
