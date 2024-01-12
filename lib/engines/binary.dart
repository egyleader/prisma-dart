library prisma.engines.binary;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:retry/retry.dart';
import 'package:webfetch/webfetch.dart' show fetch;
import '../orm.dart';

class BinaryEngine extends Engine {
  Process? _process;
  Uri? _endpoint;

  BinaryEngine({required super.schema, required super.datasources});

  /// Search for prisma binary query engine path.
  File get _executable {
    final executable = 'prisma-query-engine';
    final searchDirectories = [
      Directory.current.path,
      join(Directory.current.path, 'prisma'),
      join(Directory.current.path, '.dart_tool'),
    ];

    for (final directory in searchDirectories) {
      final file = File(join(directory, executable));
      if (file.existsSync()) return file;
    }

    throw Exception(
        'No query engine binary found ($executable) in $searchDirectories');
  }

  /// Generate owerwrite datasources.
  String get _overwriteDatasources {
    final overwrite = datasources.entries
        .map((e) => {'name': e.key, 'url': e.value})
        .toList();

    return base64.encode(utf8.encode(json.encode(overwrite)));
  }

  @override
  Future<void> start() async {
    _process ??= await _internalStart();
  }

  Future<Process> _internalStart() async {
    if (_process != null) return _process!;

    final arguments = [
      '--enable-metrics',
      '--enable-open-telemetry',
      '--enable-raw-queries',
    ];

    // Set port.
    arguments.addAll(['--port', '0']);

    // Set --datamodel
    arguments.addAll(['--datamodel', base64.encode(utf8.encode(schema))]);

    // Set protocol is json
    arguments.addAll(['--engine-protocol', 'json']);

    // Set overwrite datasources
    arguments.addAll(['--overwrite-datasources', _overwriteDatasources]);

    final process = await Process.start(
      _executable.path,
      arguments,
      includeParentEnvironment: true,
      environment: {
        'RUST_BACKTRACE': '1',
        'RUST_LOG': 'info',
      },
    );

    _listenProcess(process);
    final ready = await _serverReady();
    if (!ready) {
      process.kill();
      throw Exception('Unable to start query engine');
    }

    return process;
  }

  Future<Uri> _serverEndpoint() async {
    // Await _endpoint is not null
    // With `retry` package, retry 5 times with 1 second delay
    return retry<Uri>(
      () => _endpoint != null
          ? _endpoint!
          : throw Exception('Prisma binary query engine not ready'),
    );
  }

  /// Server ready
  Future<bool> _serverReady() async {
    // Check if server is ready
    final url = (await _serverEndpoint()).resolve('/status');

    return retry(() async {
      final response = await fetch(url);
      final data = await response.json();

      if (data case {'status': 'ok'}) {
        return true;
      }

      throw Exception('Prisma binary query engine not ready');
    });
  }

  /// Listen process
  void _listenProcess(Process process) {
    final stream =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    stream.listen((message) {
      if (message.isEmpty) return;
      try {
        final data = json.decode(message);
        if (data
            case {
              'level': "INFO",
              'target': 'query_engine::server',
              'fields': {'ip': final String host, 'port': final String port}
            }) {
          _endpoint = Uri(scheme: 'http', host: host, port: int.parse(port));
        }
      } catch (e) {
        rethrow;
      }
    });
  }

  @override
  Future<void> stop() async {
    _process?.kill();
    _process = null;
  }

  @override
  Future<Map> request(
    JsonQuery query, {
    TransactionHeaders? headers,
    Transaction? transaction,
  }) async {
    headers ??= TransactionHeaders();

    await start();
    final endpoint = await _serverEndpoint();

    if (transaction != null) {
      headers.set('x-transaction-id', transaction.id);
    }

    final response = await fetch(
      endpoint,
      headers: headers,
      body: query.toJson(),
      method: 'POST',
    );

    final result = await response.json();

    return switch (result) {
      {'data': final Map data} => deserializeJsonResponse(data),
      {'errors': final Iterable errors} => throw Exception(errors),
      _ => throw Exception(result),
    };
  }

  @override
  Future<void> commitTransaction({
    required TransactionHeaders headers,
    required Transaction transaction,
  }) async {
    await start();

    final endpoint = await _serverEndpoint();
    final response = await fetch(
      endpoint.resolve('/transaction/${transaction.id}/commit'),
      method: 'POST',
      headers: headers,
    );
    final result = await response.json();

    return switch (result) {
      {'errors': final Iterable errors} => throw Exception(errors),
      _ => null,
    };
  }

  @override
  Future<void> rollbackTransaction({
    required TransactionHeaders headers,
    required Transaction transaction,
  }) async {
    await start();

    final endpoint = await _serverEndpoint();
    final response = await fetch(
      endpoint.resolve('/transaction/${transaction.id}/rollback'),
      method: 'POST',
      headers: headers,
    );
    final result = await response.json();

    return switch (result) {
      {'errors': final Iterable errors} => throw Exception(errors),
      _ => null,
    };
  }

  @override
  Future<Transaction> startTransaction({
    required TransactionHeaders headers,
    int maxWait = 2000,
    int timeout = 5000,
    IsolationLevel? isolationLevel,
  }) async {
    await start();
    final endpoint = await _serverEndpoint();
    final response = await fetch(
      endpoint.resolve('/transaction/start'),
      method: 'POST',
      headers: headers,
      body: {
        'max_wait': maxWait,
        'timeout': timeout,
        if (isolationLevel != null) 'isolation_level': isolationLevel.name,
      },
    );
    final result = await response.json();

    return switch (result) {
      {'id': final String id} => Transaction(id),
      {'errors': final Iterable errors} => throw Exception(errors),
      _ => throw Exception(result),
    };
  }

  @override
  Future metrics({
    Map<String, String>? globalLabels,
    required MetricsFormat format,
  }) async {
    await start();

    final endpoint = await _serverEndpoint();
    final response = await fetch(
      endpoint.replace(
        path: '/metrics',
        queryParameters: {'format': format.name},
      ),
      method: 'POST',
      body: globalLabels,
    );

    return switch (format) {
      MetricsFormat.json => response.json(),
      MetricsFormat.prometheus => response.text(),
    };
  }
}
