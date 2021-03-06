// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/lsp_protocol/protocol_generated.dart';
import 'package:analysis_server/lsp_protocol/protocol_special.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/lsp/lsp_analysis_server.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/test_utilities/mock_sdk.dart';
import 'package:analyzer/src/test_utilities/resource_provider_mixin.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import '../mocks.dart';

const dartLanguageId = 'dart';

/// Useful for debugging locally, setting this to true will cause all JSON
/// communication to be printed to stdout.
const debugPrintCommunication = false;

final beginningOfDocument = new Range(new Position(0, 0), new Position(0, 0));

abstract class AbstractLspAnalysisServerTest with ResourceProviderMixin {
  static const positionMarker = '^';
  static const rangeMarkerStart = '[[';
  static const rangeMarkerEnd = ']]';
  static const allMarkers = [positionMarker, rangeMarkerStart, rangeMarkerEnd];
  static final allMarkersPattern =
      new RegExp(allMarkers.map(RegExp.escape).join('|'));

  MockLspServerChannel channel;
  LspAnalysisServer server;

  int _id = 0;
  String projectFolderPath, mainFilePath;
  Uri mainFileUri;

  final emptyTextDocumentClientCapabilities =
      new TextDocumentClientCapabilities(
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null);

  String applyEdits(String oldContent, List<TextEdit> changes) {
    String newContent = oldContent;
    // Complex text manipulations are described with an array of TextEdit's,
    // representing a single change to the document.
    //
    //  All text edits ranges refer to positions in the original document. Text
    // edits ranges must never overlap, that means no part of the original
    // document must be manipulated by more than one edit. However, it is possible
    // that multiple edits have the same start position: multiple inserts, or any
    // number of inserts followed by a single remove or replace edit. If multiple
    // inserts have the same position, the order in the array defines the order in
    // which the inserted strings appear in the resulting text.
    if (changes.length > 1) {
      // TODO(dantup): Implement multi-edit edits.
      throw 'Test helper applyEdits does not support applying multiple edits';
    } else if (changes.length == 1) {
      final change = changes.single;
      final startPos = change.range.start;
      final endPos = change.range.end;
      final lineInfo = LineInfo.fromContent(newContent);
      final start =
          lineInfo.getOffsetOfLine(startPos.line) + startPos.character;
      final end = lineInfo.getOffsetOfLine(endPos.line) + endPos.character;
      newContent = newContent.replaceRange(start, end, change.newText);
    }

    return newContent;
  }

  Future changeFile(
    int newVersion,
    Uri uri,
    List<TextDocumentContentChangeEvent> changes,
  ) async {
    var notification = makeNotification(
      Method.textDocument_didChange,
      new DidChangeTextDocumentParams(
        new VersionedTextDocumentIdentifier(newVersion, uri.toString()),
        changes,
      ),
    );
    channel.sendNotificationToServer(notification);
    await pumpEventQueue();
  }

  Future closeFile(Uri uri) async {
    var notification = makeNotification(
      Method.textDocument_didClose,
      new DidCloseTextDocumentParams(
          new TextDocumentIdentifier(uri.toString())),
    );
    channel.sendNotificationToServer(notification);
    await pumpEventQueue();
  }

  Future<Object> executeCommand(Command command) async {
    final request = makeRequest(
      Method.workspace_executeCommand,
      new ExecuteCommandParams(
        command.command,
        command.arguments,
      ),
    );
    return expectSuccessfulResponseTo(request);
  }

  Future<T> expectErrorNotification<T>(
    FutureOr<void> f(), {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final firstError = channel.errorNotificationsFromServer.first;
    await f();

    final notificationFromServer = await firstError.timeout(timeout);

    expect(notificationFromServer, isNotNull);
    return notificationFromServer.params as T;
  }

  /// Expects a [method] request from the server after executing [f].
  Future<RequestMessage> expectRequest(
    Method method,
    FutureOr<void> f(), {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final firstRequest =
        channel.requestsFromServer.firstWhere((n) => n.method == method);
    await f();

    final requestFromServer = await firstRequest.timeout(timeout);

    expect(requestFromServer, isNotNull);
    return requestFromServer;
  }

  /// Sends a request to the server and unwraps the result. Throws if the
  /// response was not successful or returned an error.
  Future<T> expectSuccessfulResponseTo<T>(RequestMessage request) async {
    final resp = await channel.sendRequestToServer(request);
    if (resp.error != null) {
      throw resp.error;
    } else {
      return resp.result as T;
    }
  }

  Future<List<TextEdit>> formatDocument(String fileUri) async {
    final request = makeRequest(
      Method.textDocument_formatting,
      new DocumentFormattingParams(
        new TextDocumentIdentifier(fileUri),
        new FormattingOptions(2, true), // These currently don't do anything
      ),
    );
    return expectSuccessfulResponseTo(request);
  }

  Future<List<TextEdit>> formatOnType(
      String fileUri, Position pos, String character) async {
    final request = makeRequest(
      Method.textDocument_onTypeFormatting,
      new DocumentOnTypeFormattingParams(
        new TextDocumentIdentifier(fileUri),
        pos,
        character,
        new FormattingOptions(2, true), // These currently don't do anything
      ),
    );
    return expectSuccessfulResponseTo(request);
  }

  Future<List<Either2<Command, CodeAction>>> getCodeActions(
    String fileUri, {
    Range range,
    List<CodeActionKind> kinds,
  }) async {
    final request = makeRequest(
      Method.textDocument_codeAction,
      new CodeActionParams(
          new TextDocumentIdentifier(fileUri),
          range ?? beginningOfDocument,
          // TODO(dantup): We may need to revise the tests/implementation when
          // it's clear how we're supposed to handle diagnostics:
          // https://github.com/Microsoft/language-server-protocol/issues/583
          new CodeActionContext([], kinds)),
    );
    return expectSuccessfulResponseTo(request);
  }

  Future<List<CompletionItem>> getCompletion(Uri uri, Position pos,
      {CompletionContext context}) async {
    final request = makeRequest(
      Method.textDocument_completion,
      new CompletionParams(
        context,
        new TextDocumentIdentifier(uri.toString()),
        pos,
      ),
    );
    return expectSuccessfulResponseTo<List<CompletionItem>>(request);
  }

  Future<List<Location>> getDefinition(Uri uri, Position pos) async {
    final request = makeRequest(
      Method.textDocument_definition,
      new TextDocumentPositionParams(
        new TextDocumentIdentifier(uri.toString()),
        pos,
      ),
    );
    return expectSuccessfulResponseTo<List<Location>>(request);
  }

  Future<Either2<List<DocumentSymbol>, List<SymbolInformation>>>
      getDocumentSymbols(String fileUri) async {
    final request = makeRequest(
      Method.textDocument_documentSymbol,
      new DocumentSymbolParams(
        new TextDocumentIdentifier(fileUri),
      ),
    );
    return expectSuccessfulResponseTo(request);
  }

  Future<Hover> getHover(Uri uri, Position pos) async {
    final request = makeRequest(
      Method.textDocument_hover,
      new TextDocumentPositionParams(
          new TextDocumentIdentifier(uri.toString()), pos),
    );
    return expectSuccessfulResponseTo<Hover>(request);
  }

  Future<List<Location>> getReferences(
    Uri uri,
    Position pos, {
    includeDeclarations = false,
  }) async {
    final request = makeRequest(
      Method.textDocument_references,
      new ReferenceParams(
        new ReferenceContext(includeDeclarations),
        new TextDocumentIdentifier(uri.toString()),
        pos,
      ),
    );
    return expectSuccessfulResponseTo<List<Location>>(request);
  }

  Future<SignatureHelp> getSignatureHelp(Uri uri, Position pos) async {
    final request = makeRequest(
      Method.textDocument_signatureHelp,
      new TextDocumentPositionParams(
        new TextDocumentIdentifier(uri.toString()),
        pos,
      ),
    );
    return expectSuccessfulResponseTo<SignatureHelp>(request);
  }

  /// Executes [f] then waits for a request of type [method] from the server which
  /// is passed to [handler] to process, then waits for (and returns) the
  /// response to the original request.
  ///
  /// This is used for testing things like code actions, where the client initiates
  /// a request but the server does not respond to it until it's sent its own
  /// request to the client and it recieved a response.
  ///
  ///     Client                                 Server
  ///     1. |- Req: textDocument/codeAction      ->
  ///     1. <- Resp: textDocument/codeAction     -|
  ///
  ///     2. |- Req: workspace/executeCommand  ->
  ///           3. <- Req: textDocument/applyEdits  -|
  ///           3. |- Resp: textDocument/applyEdits ->
  ///     2. <- Resp: workspace/executeCommand -|
  ///
  /// Request 2 from the client is not responded to until the server has its own
  /// response to the request it sends (3).
  Future<T> handleExpectedRequest<T, R, RR>(
    Method method,
    Future<T> f(), {
    @required FutureOr<RR> handler(R params),
    Duration timeout = const Duration(seconds: 5),
  }) async {
    FutureOr<T> outboundRequest;

    // Run [f] and wait for the incoming request from the server.
    final incomingRequest = await expectRequest(method, () {
      // Don't return/await the response yet, as this may not complete until
      // after we have handled the request that comes from the server.
      outboundRequest = f();
    });

    // Handle the request from the server and send the response back.
    final clientsResponse = await handler(incomingRequest.params as R);
    respondTo(incomingRequest, clientsResponse);

    // Return a future that completes when the response to the original request
    // (from [f]) returns.
    return outboundRequest;
  }

  /// A helper that initializes the server with common values, since the server
  /// will reject any other requests until it is initialized.
  /// Capabilities are overridden by providing JSON to avoid having to construct
  /// full objects just to change one value (the types are immutable) so must
  /// match the spec exactly and are not verified.
  Future<ResponseMessage> initialize({
    String rootPath,
    Map<String, dynamic> textDocumentCapabilities,
  }) async {
    final rootUri = Uri.file(rootPath ?? projectFolderPath).toString();
    final newTextDocumentCapabilities =
        overrideTextDocumentCapabilities(textDocumentCapabilities);
    final request = makeRequest(
        Method.initialize,
        new InitializeParams(
            null,
            null,
            rootUri,
            null,
            new ClientCapabilities(null, newTextDocumentCapabilities, null),
            null,
            null));
    final response = await channel.sendRequestToServer(request);
    expect(response.id, equals(request.id));

    if (response.error == null) {
      final notification = makeNotification(Method.initialized, null);
      channel.sendNotificationToServer(notification);
    }

    return response;
  }

  NotificationMessage makeNotification(Method method, ToJsonable params) {
    return new NotificationMessage(method, params, jsonRpcVersion);
  }

  RequestMessage makeRequest(Method method, ToJsonable params) {
    final id = Either2<num, String>.t1(_id++);
    return new RequestMessage(id, method, params, jsonRpcVersion);
  }

  Future openFile(Uri uri, String content) async {
    var notification = makeNotification(
      Method.textDocument_didOpen,
      new DidOpenTextDocumentParams(
          new TextDocumentItem(uri.toString(), dartLanguageId, 1, content)),
    );
    channel.sendNotificationToServer(notification);
    await pumpEventQueue();
  }

  TextDocumentClientCapabilities overrideTextDocumentCapabilities(
      Map<String, dynamic> textDocumentCapabilities) {
    final json = emptyTextDocumentClientCapabilities.toJson();
    if (textDocumentCapabilities != null) {
      textDocumentCapabilities.keys.forEach((key) {
        json[key] = textDocumentCapabilities[key];
      });
    }
    final newTextDocumentCapabilities =
        TextDocumentClientCapabilities.fromJson(json);
    return newTextDocumentCapabilities;
  }

  Position positionFromMarker(String contents) =>
      positionFromOffset(contents.indexOf('^'), contents);

  Position positionFromOffset(int offset, String contents) {
    final lineInfo = LineInfo.fromContent(contents);
    return toPosition(lineInfo.getLocation(offset));
  }

  /// Returns the range surrounded by `[[markers]]` in the provided string,
  /// excluding the markers themselves (as well as position markers `^` from
  /// the offsets).
  Range rangeFromMarkers(String contents) {
    contents = contents.replaceAll(positionMarker, '');
    final start = contents.indexOf(rangeMarkerStart);
    if (start == -1) {
      throw 'Contents did not contain $rangeMarkerStart';
    }
    final end = contents.indexOf(rangeMarkerEnd);
    if (end == -1) {
      throw 'Contents did not contain $rangeMarkerEnd';
    }
    return new Range(
      positionFromOffset(start, contents),
      positionFromOffset(end - rangeMarkerStart.length, contents),
    );
  }

  Future replaceFile(int newVersion, Uri uri, String content) async {
    await changeFile(
      newVersion,
      uri,
      [new TextDocumentContentChangeEvent(null, null, content)],
    );
  }

  /// Sends [responseParams] to the server as a successful response to
  /// a server-initiated [request].
  void respondTo<T>(RequestMessage request, T responseParams) async {
    channel.sendResponseToServer(
        new ResponseMessage(request.id, responseParams, null, jsonRpcVersion));
  }

  void setUp() {
    channel = new MockLspServerChannel(debugPrintCommunication);
    // Create an SDK in the mock file system.
    new MockSdk(resourceProvider: resourceProvider);
    server = new LspAnalysisServer(
        channel,
        resourceProvider,
        new AnalysisServerOptions(),
        new DartSdkManager(convertPath('/sdk'), false),
        InstrumentationService.NULL_SERVICE);

    projectFolderPath = convertPath('/project');
    newFolder(projectFolderPath);
    newFolder(join(projectFolderPath, 'lib'));
    // Create a folder and file to aid testing that includes imports/completion.
    newFolder(join(projectFolderPath, 'lib', 'folder'));
    newFile(join(projectFolderPath, 'lib', 'file.dart'));
    mainFilePath = join(projectFolderPath, 'lib', 'main.dart');
    mainFileUri = Uri.file(mainFilePath);
  }

  Future tearDown() async {
    channel.close();
    await server.shutdown();
  }

  Future<List<Diagnostic>> waitForDiagnostics(Uri uri) async {
    PublishDiagnosticsParams diagnosticParams;
    await channel.serverToClient.firstWhere((message) {
      if (message is NotificationMessage &&
          message.method == Method.textDocument_publishDiagnostics) {
        diagnosticParams = message.params;

        return diagnosticParams.uri == uri.toString();
      }
      return false;
    });
    return diagnosticParams.diagnostics;
  }

  /// Removes markers like `[[` and `]]` and `^` that are used for marking
  /// positions/ranges in strings to avoid hard-coding positions in tests.
  String withoutMarkers(String contents) =>
      contents.replaceAll(allMarkersPattern, '');
}
