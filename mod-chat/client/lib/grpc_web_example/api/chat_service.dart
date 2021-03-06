import 'dart:isolate';
import 'dart:io';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:grpc/grpc.dart';
import 'package:mod_chat/grpc_web_example/blocs/message_events.dart';
import 'package:mod_chat/grpc_web_example/models/message_outgoing.dart';

import 'package:mod_chat/grpc_web_example/api/v1/service.pbgrpc.dart' as grpc;
import 'package:mod_chat/mod_chat.dart';

/// CHANGE TO IP ADDRESS OF YOUR SERVER IF IT IS NECESSARY
const serverPort = 433;

/// ChatService client implementation
class ChatService {
  // _isolateSending is isolate to send chat messages
  Isolate _isolateSending;

  // Port to send message
  SendPort _portSending;

  // Port to get status of message sending
  ReceivePort _portSendStatus;

  // _isolateReceiving is isolate to receive chat messages
  Isolate _isolateReceiving;

  // Port to receive messages
  ReceivePort _portReceiving;

  /// Event is raised when message has been sent to the server successfully
  final void Function(MessageSentEvent event) onMessageSent;

  /// Event is raised when message sending is failed
  final void Function(MessageSendFailedEvent event) onMessageSendFailed;

  /// Event is raised when message has been received from the server
  final void Function(MessageReceivedEvent event) onMessageReceived;

  /// Event is raised when message receiving is failed
  final void Function(MessageReceiveFailedEvent event) onMessageReceiveFailed;

  /// Constructor
  ChatService({this.onMessageSent,
    this.onMessageSendFailed,
    this.onMessageReceived,
    this.onMessageReceiveFailed})
      : _portSendStatus = ReceivePort(),
        _portReceiving = ReceivePort();

  // Start threads to send and receive messages
  void start() {
    _startSending();
    _startReceiving();
  }

  /// Start thread to send messages
  void _startSending() async {
    // start thread to send messages
    _isolateSending =
    await Isolate.spawn(_sendingIsolate, _portSendStatus.sendPort);

    // listen send status
    await for (var event in _portSendStatus) {
      if (event is SendPort) {
        _portSending = event;
        event.send(ChatModule.chatModuleConfig);
      } else if (event is MessageSentEvent) {
        // call for success handler
        if (onMessageSent != null) {
          onMessageSent(event);
        }
      } else if (event is MessageSendFailedEvent) {
        // call for error handler
        if (onMessageSendFailed != null) {
          onMessageSendFailed(event);
        }
      } else {
        assert(false, 'Unknown event type ${event.runtimeType}');
      }
    }
  }

  /// Thread to send messages
  static void _sendingIsolate(SendPort portSendStatus) async {
    // Port to get messages to send
    ReceivePort portSendMessages = ReceivePort();

    // send port to send messages to the caller
    portSendStatus.send(portSendMessages.sendPort);

    String hostUrl;
    //handshake here we are sending back a port with which we receive
    //the correct host url

    ClientChannel client;
    // waiting messages to send
    await for (var message in portSendMessages) {
      if (message is ChatModuleConfig) {
        hostUrl = message.urlNative;
      } else if (message is MessageOutgoing) {
        var sent = false;
         print("Sending Isolate : HOST URL -> $hostUrl");
        do {
          // create new client
          client ??= ClientChannel(
            hostUrl, // Your IP here or localhost
            port: serverPort,
            options: ChannelOptions(
              //TODO: Change to secure with server certificates
              credentials: ChannelCredentials.secure(),
              idleTimeout: Duration(seconds: 1),
            ),
          );

          print("Sending Isolate : Client Port  -> ${client.port}");

          try {
            // try to send
            var msg = grpc.Message.create();
            msg.id = "0";
            msg.content = message.text;
            msg.timestamp = DateTime.now().toString();
            await grpc.BroadcastClient(client).broadcastMessage(msg);

            // sent successfully
            portSendStatus.send(MessageSentEvent(id: message.id));
            sent = true;
          } catch (e) {
            // sent failed
            portSendStatus.send(
                MessageSendFailedEvent(id: message.id, error: e.toString()));
            // reset client
            client.shutdown();
            client = null;
          }

          if (!sent) {
            // try to send again
            sleep(Duration(seconds: 5));
          }
        } while (!sent);
      }
    }
  }

  /// Start listening messages from the server
  void _startReceiving() async {
    // start thread to receive messages
    _isolateReceiving = await Isolate.spawn(
      _receivingIsolate,
      _portReceiving.sendPort,
    );

    // listen for incoming messages
    await for (var event in _portReceiving) {
      if (event is SendPort) {
        // send chat module config to isolate for initialization
        event.send(ChatModule.chatModuleConfig);
      }
      if (event is MessageReceivedEvent) {
        if (onMessageReceived != null) {
          onMessageReceived(event);
        }
      } else if (event is MessageReceiveFailedEvent) {
        if (onMessageReceiveFailed != null) {
          onMessageReceiveFailed(event);
        }
      }
    }
  }

  /// Thread to listen messages from the server
  static void _receivingIsolate(SendPort portReceive) async {
    ClientChannel client;

    String hostUrl;
    //handshake here we are sending back a port with which we receive
    //the correct host url
    ReceivePort newReceivePort = ReceivePort();
    portReceive.send(newReceivePort.sendPort);

    //wait for host url and then go on!
    await for (var message in newReceivePort){
      if (message is ChatModuleConfig) {
        hostUrl = message.urlNative;
        break;
      }
    }

    do {
      // create new client
      print("Receiving Isolate : HOST URL -> $hostUrl");
      
      if (hostUrl != null) {
       
        client ??= ClientChannel(
          hostUrl, // Your IP here or localhost
          port: serverPort,
          options: ChannelOptions(
            //TODO: Change to secure with server certificates
            credentials: ChannelCredentials.secure(),
            idleTimeout: Duration(seconds: 1),
          ),
        );

         print("Receiving Isolate : Client Port  -> ${client.port}");
          print("Receiving Isolate : Client isSecure?  -> ${client.options.credentials.isSecure}");

        var stream = grpc.BroadcastClient(client).createStream(grpc.Connect());

        try {
          await for (var message in stream) {
            portReceive.send(MessageReceivedEvent(text: message.content));
          }
        } catch (e) {
          // notify caller
          portReceive.send(MessageReceiveFailedEvent(error: e.toString()));
          // reset client
          client.shutdown();
          client = null;
        }
      }
      // try to connect again
      sleep(Duration(milliseconds: (hostUrl == null) ? 1000 : 5000));
    } while (true);
  }

  // Shutdown client
  void shutdown() {
    // stop sending
    _isolateSending?.kill(priority: Isolate.immediate);
    _isolateSending = null;
    _portSendStatus?.close();
    _portSendStatus = null;

    // stop receiving
    _isolateReceiving?.kill(priority: Isolate.immediate);
    _isolateReceiving = null;
    _portReceiving?.close();
    _portReceiving = null;
  }

  /// Send message to the server
  void send(MessageOutgoing message) {
    assert(_portSending != null, "Port to send message can't be null");
    _portSending.send(message);
  }
}
