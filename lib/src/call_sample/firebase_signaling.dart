import 'dart:async';
import 'dart:convert';
import 'dart:io';

import "package:firebase_core/firebase_core.dart";
import "package:firebase_database/firebase_database.dart";
import 'package:flutter_webrtc/webrtc.dart';

enum SignalingState {
    CallStateNew,
    CallStateRinging,
    CallStateInvite,
    CallStateConnected,
    CallStateBye,
    ConnectionOpen,
    ConnectionReady,
    ConnectionClosed,
    ConnectionError,
}

/*
 * callbacks for Signaling API.
 */
typedef void SignalingStateCallback(SignalingState state);
typedef void StreamStateCallback(MediaStream stream);
typedef void OtherEventCallback(dynamic event);
typedef void DataChannelMessageCallback(RTCDataChannel dc, data);
typedef void DataChannelCallback(RTCDataChannel dc);

class FirebaseSignaling {
    String _selfId = "";
    var _sessionId;
    var _name;
    var _peerConnections = new Map<String, RTCPeerConnection>();
    var _dataChannels = new Map<String, RTCDataChannel>();

    FirebaseDatabase _fbDatabase;
    DatabaseReference _peersRef;
    DatabaseReference _signalingRef;
    StreamSubscription<Event> _signalingSubscription;
    StreamSubscription<Event> _peersSubscription;
    var _peers = new Map<String, dynamic>();

    MediaStream _localStream;
    List<MediaStream> _remoteStreams;
    SignalingStateCallback onStateChange;
    StreamStateCallback onLocalStream;
    StreamStateCallback onAddRemoteStream;
    StreamStateCallback onRemoveRemoteStream;
    OtherEventCallback onPeersUpdate;
    DataChannelMessageCallback onDataChannelMessage;
    DataChannelCallback onDtaChannel;

    Map<String, dynamic> _iceServers = {
        'iceServers': [
            {'url': 'stun:stun.l.google.com:19302'},
            {
                'url': 'turn:142.93.254.218:3478',
                'username': 'lixu',
                'credential': 'pass01!'
            },
        ]
    };

    final Map<String, dynamic> _config = {
        'mandatory': {},
        'optional': [
            {'DtlsSrtpKeyAgreement': true},
        ],
    };

    final Map<String, dynamic> _constraints = {
        'mandatory': {
            'OfferToReceiveAudio': true,
            'OfferToReceiveVideo': true,
        },
        'optional': [],
    };

    final Map<String, dynamic> _dc_constraints = {
        'mandatory': {
            'OfferToReceiveAudio': false,
            'OfferToReceiveVideo': false,
        },
        'optional': [],
    };

    FirebaseSignaling(this._name);

    close() {
        if (_localStream != null) {
            _localStream.dispose();
            _localStream = null;
        }

        _peerConnections.forEach((key, pc) {
            pc.close();
        });

        _unregisterSelf();

        _stopListeningPeers();
        _stopListeningMessages();

        if (this.onStateChange != null) {
            this.onStateChange(SignalingState.ConnectionClosed);
        }
    }

    void switchCamera() {
        if (_localStream != null) {
            _localStream.getVideoTracks()[0].switchCamera();
        }
    }

    void invite(String peer_id, String media, use_screen) {
        this._sessionId = this._selfId + '-' + peer_id;

        // update session id
        _getPeersRef().child("$_selfId/session_id").set(this._sessionId);

        if (this.onStateChange != null) {
            this.onStateChange(SignalingState.CallStateNew);
        }

        _createPeerConnection(peer_id, media, use_screen).then((pc) {
            _peerConnections[peer_id] = pc;
            if (media == 'data') {
                _createDataChannel(peer_id, pc);
            }
            _createOffer(peer_id, pc, media);
        });
    }

    void bye() {
        _send('bye', {
            'type': 'bye',
            'data': {
                'session_id': this._sessionId,
                'from': this._selfId,
            }
        });
    }

    Future<bool> onMessage(message) async {
        Map<String, dynamic> mapData = message;
        var data = mapData['data'];
        var to = data != null && data.containsKey("to") ? data['to'] : "";

        if (to != "" && _selfId != to) {
            return false;
        }

        switch (mapData['type']) {
            case 'offer':
                {
                    var id = data['from'];
                    var description = data['description'];
                    var media = data['media'];
                    var sessionId = data['session_id'];
                    this._sessionId = sessionId;

                    _getPeersRef().child("$_selfId/session_id").set(sessionId);

                    if (this.onStateChange != null) {
                        this.onStateChange(SignalingState.CallStateNew);
                    }

                    _createPeerConnection(id, media, false).then((pc) {
                        _peerConnections[id] = pc;
                        pc.setRemoteDescription(new RTCSessionDescription(description['sdp'], description['type']));
                        _createAnswer(id, pc, media);
                    });
                }
                break;
            case 'answer':
                {
                    var id = data['from'];
                    var description = data['description'];

                    var pc = _peerConnections[id];
                    if (pc != null) {
                        pc.setRemoteDescription(new RTCSessionDescription(description['sdp'], description['type']));
                    }
                }
                break;
            case 'candidate':
                {
                    var id = data['from'];
                    var candidateMap = data['candidate'];
                    var pc = _peerConnections[id];

                    if (pc != null) {
                        RTCIceCandidate candidate = new RTCIceCandidate(
                            candidateMap['candidate'],
                            candidateMap['sdpMid'],
                            candidateMap['sdpMLineIndex']);
                        pc.addCandidate(candidate);
                    }
                }
                break;
            case 'bye':
                {
                    var sessionId = data['session_id'];
                    if (this._sessionId != sessionId) {
                        return false;
                    }

                    print('bye: ' + sessionId);

                    if (_localStream != null) {
                        _localStream.dispose();
                        _localStream = null;
                    }

                    var to = "";
                    _peers.forEach((k, v) {
                        if (v.containsKey('session_id') && v['session_id'] == sessionId) {
                            to = k;
                        }
                    });


                    if (to != "") {
                        var pc = _peerConnections[to];
                        if (pc != null) {
                            pc.close();
                            _peerConnections.remove(to);
                        }

                        var dc = _dataChannels[to];
                        if (dc != null) {
                            dc.close();
                            _dataChannels.remove(to);
                        }

                        this._sessionId = null;
                        if (this.onStateChange != null) {
                            this.onStateChange(SignalingState.CallStateBye);
                        }
                    }

                    _peersRef.child("$_selfId/session_id").remove();
                }
                break;
            case 'keepalive':
                {
                    print('keepalive response!');
                }
                break;
            default:
                break;
        }

        return true;
    }

    void connect() async {
        try {
            if (this.onStateChange != null) {
                this.onStateChange(SignalingState.ConnectionOpen);
            }

            await _setupFBDatabase();
            _startListeningPeers();
            _startListeningMessages();

            await _registerSelf();

            if (this.onStateChange != null) {
                this.onStateChange(SignalingState.ConnectionReady);
            }
        } catch (e) {
            if (this.onStateChange != null) {
                this.onStateChange(SignalingState.ConnectionError);
            }

            print("Connect failed: ${e.toString()}");
        }
    }

    Future<MediaStream> createStream(media, user_screen) async {
        final Map<String, dynamic> mediaConstraints = {
            'audio': true,
            'video': {
                'mandatory': {
                    'minWidth':
                    '640', // Provide your own width, height and frame rate here
                    'minHeight': '480',
                    'minFrameRate': '30',
                },
                'facingMode': 'user',
                'optional': [],
            }
        };

        MediaStream stream = user_screen
            ? await navigator.getDisplayMedia(mediaConstraints)
            : await navigator.getUserMedia(mediaConstraints);
        if (this.onLocalStream != null) {
            this.onLocalStream(stream);
        }
        return stream;
    }

    _createPeerConnection(id, media, user_screen) async {
        if (media != 'data') {
            _localStream = await createStream(media, user_screen);
        }

        RTCPeerConnection pc = await createPeerConnection(_iceServers, _config);
        if (media != 'data') {
            pc.addStream(_localStream);
        }

        pc.onIceCandidate = (candidate) {
            _send('candidate', {
                'type': "candidate",
                'data': {
                    'from': _selfId,
                    'to': id,
                    'candidate': {
                        'sdpMLineIndex': candidate.sdpMlineIndex,
                        'sdpMid': candidate.sdpMid,
                        'candidate': candidate.candidate,
                    },
                    'session_id': this._sessionId,
                }
            });
        };

        pc.onIceConnectionState = (state) {};

        pc.onAddStream = (stream) {
            if (this.onAddRemoteStream != null) {
                this.onAddRemoteStream(stream);
            }
        };

        pc.onRemoveStream = (stream) {
            if (this.onRemoveRemoteStream != null) {
                this.onRemoveRemoteStream(stream);
            }

            _remoteStreams.removeWhere((it) {
                return (it.id == stream.id);
            });
        };

        pc.onDataChannel = (channel) {
            _addDataChannel(id, channel);
        };

        return pc;
    }


    _addDataChannel(id, RTCDataChannel channel) {
        channel.onDataChannelState = (e) {};
        channel.onMessage = (data) {
            if (this.onDataChannelMessage != null)
                this.onDataChannelMessage(channel, data);
        };
        _dataChannels[id] = channel;

        if (this.onDtaChannel != null) this.onDtaChannel(channel);
    }

    _createDataChannel(id, RTCPeerConnection pc, {label: 'fileTransfer'}) async {
        RTCDataChannelInit dataChannelDict = new RTCDataChannelInit();
        RTCDataChannel channel = await pc.createDataChannel(label, dataChannelDict);
        _addDataChannel(id, channel);
    }

    _createOffer(String id, RTCPeerConnection pc, String media) async {
        try {
            RTCSessionDescription s = await pc.createOffer(media == 'data' ? _dc_constraints : _constraints);
            pc.setLocalDescription(s);
            _send('offer', {
                'type': 'offer',
                'data': {
                    'from': _selfId,
                    'to': id,
                    'description': {'sdp': s.sdp, 'type': s.type},
                    'session_id': this._sessionId,
                    'media': media,
                }
            });
        } catch (e) {
            print(e.toString());
        }
    }

    _createAnswer(String id, RTCPeerConnection pc, media) async {
        try {
            RTCSessionDescription s = await pc
                .createAnswer(media == 'data' ? _dc_constraints : _constraints);
            pc.setLocalDescription(s);
            _send('answer', {
                'type': 'answer',
                'data': {
                    'from': _selfId,
                    'to': id,
                    'description': {'sdp': s.sdp, 'type': s.type},
                    'session_id': this._sessionId,
                }
            });
        } catch (e) {
            print(e.toString());
        }
    }

    Future<FirebaseDatabase> _setupFBDatabase() async {
        if (_fbDatabase == null) {
            _fbDatabase = FirebaseDatabase.instance;

            if (_fbDatabase == null) {
                final FirebaseApp app = await FirebaseApp.configure(
                    name: 'default',
                    options: const FirebaseOptions(
                        googleAppID: "1:1087858601751:android:4deb03171cc4ef70",
                        databaseURL: "https://webrtc-demo-f566e.firebaseio.com",
                    )
                );
                _fbDatabase = new FirebaseDatabase(app: app);
            }
        }

        return _fbDatabase;
    }

    DatabaseReference _getPeersRef() {
        if (_peersRef == null) {
            _peersRef = _fbDatabase.reference().child("peers");
        }

        return _peersRef;
    }

    DatabaseReference _getSignalingRef() {
        if (_signalingRef == null) {
            _signalingRef = _fbDatabase.reference().child("signaling");
        }

        return _signalingRef;
    }

    _registerSelf() async {
        DatabaseReference childRef = _peersRef.push();

        _selfId = childRef.key;

        await childRef.set({
            'id': _selfId,
            'name': _name,
            'user_agent': 'flutter-webrtc/' + Platform.operatingSystem + '-plugin 0.0.1'
        });

        childRef.onDisconnect().remove();

        print("registered, id: " + _selfId);
    }

    _unregisterSelf() async {
        await _peersRef.child(_selfId).remove();

        print("unregistered, id: " + _selfId);

        _selfId = "";
    }

    _startListeningPeers() {
        if (_peersSubscription == null) {
            _peersSubscription = _getPeersRef()
                .onValue
                .listen((Event event) {
                _peers = new Map<String, dynamic>.from(event.snapshot.value);
                if (this.onPeersUpdate != null) {
                    Map<String, dynamic> event = new Map<String, dynamic>();
                    event['self'] = _selfId;
                    event['peers'] = new List.from(_peers.values);
                    this.onPeersUpdate(event);
                }

                print("Received peers: " + _peers.length.toString());
            }, onError: (Object o) {
                final DatabaseError error = o;
                print('Error: ${error.code} ${error.message}');
            });
        }
    }

    _stopListeningPeers() {
        if (_peersSubscription != null) {
            _peersSubscription.cancel();
            _peersSubscription = null;
        }
    }

    _startListeningMessages() {
        if (_signalingSubscription == null) {
            _signalingSubscription =
                _getSignalingRef()
                    .onChildAdded
                    .listen((Event event) async {
                    JsonDecoder decoder = new JsonDecoder();
                    if (await this.onMessage(
                        decoder.convert(event.snapshot.value))) {
                        // remove the processed message
                        _signalingRef.child(event.snapshot.key).remove();
                    }
                    print('Child added: ${event.snapshot.value}');
                }, onError: (Object o) {
                    final DatabaseError error = o;
                    print('Error: ${error.code} ${error.message}');
                });
        }
    }

    _stopListeningMessages() {
        if (_signalingSubscription != null) {
            _signalingSubscription.cancel();
            _signalingSubscription = null;
        }
    }

    _send(event, data) {
        data['type'] = event;

        JsonEncoder encoder = new JsonEncoder();
        _getSignalingRef().push().set(encoder.convert(data));

        print('send: ' + encoder.convert(data));
    }
}
