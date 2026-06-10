import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'openleash_public_config.dart';

const _productionCloudApiUrl = openLeashPublicCloudApiUrl;
const _redirectUri = openLeashAuthCallbackUri;
const _storageKey = 'openleash.mobile.session.v1';
const _functionHeader = 'x-openleash-api-function';
const _versionHeader = 'x-openleash-api-version';
const _contracts = <String, String>{
  'mobileBootstrap': '2026-05-22.mobile-bootstrap.v1',
  'mobileAuthStart': '2026-05-22.mobile-auth-start.v1',
  'mobileAuthExchange': '2026-05-22.mobile-auth-exchange.v1',
  'mobileDeviceRegister': '2026-05-22.mobile-device-register.v1',
  'mobileState': '2026-05-22.mobile-state.v1',
  'mobileDecisionResolve': '2026-05-22.mobile-decision-resolve.v1',
};

String _defaultCloudApiUrl() {
  const configured = String.fromEnvironment('OPENLEASH_CLOUD_API_URL');
  if (configured.isNotEmpty) return configured;
  if (kDebugMode) {
    if (Platform.isAndroid) return 'http://10.0.2.2:9318';
    return 'http://localhost:9318';
  }
  return _productionCloudApiUrl;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = ApprovalNotifications();
  await notifications.init();
  runApp(OpenLeashMobileApp(notifications: notifications));
}

class OpenLeashMobileApp extends StatelessWidget {
  const OpenLeashMobileApp({super.key, required this.notifications});

  final ApprovalNotifications notifications;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenLeash',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xffeef1f6),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffbed0ff),
          brightness: Brightness.light,
        ),
        fontFamily: Platform.isIOS ? 'SF Pro Display' : null,
        textTheme: Theme.of(context).textTheme.apply(
          bodyColor: const Color(0xff0f1219),
          displayColor: const Color(0xff0f1219),
        ),
      ),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.88,
              maxScaleFactor: Platform.isIOS ? 0.92 : 0.96,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: OpenLeashHome(notifications: notifications),
    );
  }
}

class OpenLeashHome extends StatefulWidget {
  const OpenLeashHome({super.key, required this.notifications});

  final ApprovalNotifications notifications;

  @override
  State<OpenLeashHome> createState() => _OpenLeashHomeState();
}

class _OpenLeashHomeState extends State<OpenLeashHome> {
  final _storage = const FlutterSecureStorage();
  final _appLinks = AppLinks();
  final _apiController = TextEditingController(text: _defaultCloudApiUrl());
  final _deviceId = DateTime.now().microsecondsSinceEpoch.toString();
  StreamSubscription<Uri>? _linkSub;
  Timer? _poller;

  bool _loading = true;
  bool _customApi = false;
  bool _busy = false;
  String _audience = 'individual';
  String? _error;
  String? _token;
  String? _pendingProvider;
  String? _pendingOrganizationId;
  String? _pendingExchangeRedirectUri;
  Map<String, dynamic>? _bootstrap;
  Map<String, dynamic>? _state;
  final Set<String> _notifiedApprovalIds = {};

  String get _apiUrl =>
      _apiController.text.trim().replaceAll(RegExp(r'/$'), '');
  List<String> get _apiCandidates {
    if (_customApi) return [_apiUrl];
    final localDevCandidates = kDebugMode
        ? Platform.isAndroid
              ? const ['http://10.0.2.2:9318', 'http://localhost:9318']
              : const ['http://localhost:9318', 'http://127.0.0.1:9318']
        : const <String>[];
    return <String>{
      _defaultCloudApiUrl(),
      ...localDevCandidates,
      _productionCloudApiUrl,
    }.toList();
  }

  bool get _signedIn => _token != null && _token!.isNotEmpty;
  List<dynamic> get _providers =>
      (_bootstrap?['providers'] as List?) ?? const [];
  List<dynamic> get _pendingApprovals =>
      (_state?['pendingApprovals'] as List?) ?? const [];
  List<dynamic> get _agents => (_state?['agents'] as List?) ?? const [];
  List<dynamic> get _recentActivity =>
      (_state?['recentActivity'] as List?) ?? const [];

  @override
  void initState() {
    super.initState();
    widget.notifications.onDecision = _resolveFromNotification;
    _linkSub = _appLinks.uriLinkStream.listen(_handleIncomingLink);
    _restore();
  }

  @override
  void dispose() {
    _poller?.cancel();
    _linkSub?.cancel();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw != null) {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      _customApi = saved['customApi'] == true;
      final savedApiUrl = saved['apiUrl'] as String?;
      _apiController.text = _customApi
          ? savedApiUrl ?? _defaultCloudApiUrl()
          : _defaultCloudApiUrl();
      _token = saved['token'] as String?;
    }
    if (_signedIn) {
      final bootstrapped = await _bootstrapApi();
      if (!bootstrapped) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      await _registerDevice();
      await _refreshState(showNotifications: true);
      _startPolling();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode({
        'apiUrl': _apiUrl,
        'customApi': _customApi,
        'token': _token,
      }),
    );
  }

  Map<String, String> _headers(String functionName, {bool json = false}) {
    return {
      _functionHeader: functionName,
      _versionHeader: _contracts[functionName]!,
      if (json) 'content-type': 'application/json',
      if (_token != null) 'authorization': 'Bearer $_token',
    };
  }

  Future<http.Response> _request(
    String method,
    String path,
    String functionName, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$_apiUrl$path').replace(queryParameters: query);
    final headers = _headers(functionName, json: body != null);
    if (method == 'POST') {
      return http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    }
    return http.get(uri, headers: headers);
  }

  Future<bool> _bootstrapApi() async {
    setStateSafe(() {
      _busy = true;
      _error = null;
    });
    Object? lastError;
    try {
      for (final candidate in _apiCandidates) {
        _apiController.text = candidate;
        try {
          final response = await _request(
            'GET',
            '/v1/mobile/bootstrap',
            'mobileBootstrap',
          );
          if (response.statusCode >= 400) {
            throw Exception(await _responseMessage(response));
          }
          _bootstrap = jsonDecode(response.body) as Map<String, dynamic>;
          await _save();
          return true;
        } catch (error) {
          lastError = error;
        }
      }
      _error =
          'Could not reach OpenLeash at ${_apiCandidates.join(' or ')}. Check that the API is running and try again.';
      return false;
    } catch (error) {
      _error =
          'Could not connect to OpenLeash. ${_cleanError(lastError ?? error)}';
      return false;
    } finally {
      setStateSafe(() => _busy = false);
    }
  }

  Future<void> _startSignIn([String? providerOverride]) async {
    setStateSafe(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _bootstrapApi()) return;
      final provider = providerOverride != null
          ? {'type': providerOverride}
          : _providers.isNotEmpty
          ? _providers.first as Map<String, dynamic>
          : {'type': 'google'};
      _pendingProvider =
          provider['type'] as String? ??
          provider['providerType'] as String? ??
          'google';
      _pendingOrganizationId =
          (_bootstrap?['organization'] as Map?)?['id'] as String?;
      final response = await _request(
        'POST',
        '/v1/mobile/auth/start',
        'mobileAuthStart',
        body: {
          'redirectUri': _redirectUri,
          'audience': _audience,
          'providerType': _pendingProvider,
          'organizationId': _pendingOrganizationId,
        },
      );
      if (response.statusCode >= 400) {
        throw Exception(await _responseMessage(response));
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _pendingExchangeRedirectUri =
          data['exchangeRedirectUri'] as String? ?? _redirectUri;
      final url = Uri.parse(data['authorizationUrl'] as String);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not open identity provider.');
      }
    } catch (error) {
      final message = _cleanError(error);
      _error =
          message.contains('OPENLEASH_GOOGLE_CLIENT_ID') ||
              message.contains('Cloud Google login is not configured')
          ? 'Google sign-in is not configured on this API yet.'
          : 'Could not start Google sign-in. $message';
    } finally {
      setStateSafe(() => _busy = false);
    }
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    if (uri.scheme != 'openleash' || uri.host != 'auth') return;
    final error =
        uri.queryParameters['error_description'] ??
        uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      setStateSafe(() => _error = 'Google sign-in did not complete. $error');
      return;
    }
    final exchangeRedirectUri = uri.queryParameters['exchangeRedirectUri'];
    final audience = uri.queryParameters['audience'];
    if (audience == 'organization' || audience == 'individual') {
      _audience = audience!;
    }
    if (exchangeRedirectUri != null && exchangeRedirectUri.isNotEmpty) {
      _pendingExchangeRedirectUri = exchangeRedirectUri;
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      setStateSafe(
        () => _error = 'Sign-in was cancelled or returned without a code.',
      );
      return;
    }
    await _exchangeCode(code);
  }

  Future<void> _exchangeCode(String code) async {
    setStateSafe(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await _request(
        'POST',
        '/v1/mobile/auth/exchange',
        'mobileAuthExchange',
        body: {
          'redirectUri': _pendingExchangeRedirectUri ?? _redirectUri,
          'audience': _audience,
          'authorizationCode': code,
          'providerType': _pendingProvider ?? 'google',
          'organizationId': _pendingOrganizationId,
          'provisionUser': false,
        },
      );
      if (response.statusCode >= 400) {
        throw Exception(await _responseMessage(response));
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _token =
          data['token'] as String? ??
          data['sessionToken'] as String? ??
          data['session']?['token'] as String? ??
          data['tokens']?['accessToken'] as String?;
      if (_token == null) throw Exception('No session token returned.');
      await _save();
      await _registerDevice();
      await _refreshState(showNotifications: true);
      _startPolling();
    } catch (error) {
      _error =
          'Sign-in completed, but OpenLeash could not create the mobile session. ${_cleanError(error)}';
    } finally {
      setStateSafe(() => _busy = false);
    }
  }

  Future<void> _registerDevice() async {
    if (!_signedIn) return;
    await widget.notifications.requestPermissions();
    try {
      await _request(
        'POST',
        '/v1/mobile/devices',
        'mobileDeviceRegister',
        body: {
          'platform': Platform.isIOS ? 'ios' : 'android',
          'pushToken': 'local-polling:$_deviceId',
          'deviceName': Platform.localHostname,
          'appVersion': '1.0.0',
        },
      );
    } catch (_) {
      // Polling still works even if registration fails during local development.
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshState(showNotifications: true),
    );
  }

  Future<void> _refreshState({bool showNotifications = false}) async {
    if (!_signedIn) return;
    try {
      final response = await _request('GET', '/v1/mobile/state', 'mobileState');
      if (response.statusCode == 401) {
        await _signOut();
        return;
      }
      if (response.statusCode >= 400) throw Exception(response.body);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      setStateSafe(() => _state = data);
      if (showNotifications) {
        for (final approval in _pendingApprovals.cast<Map>()) {
          final id = approval['id']?.toString();
          if (id == null || _notifiedApprovalIds.contains(id)) continue;
          _notifiedApprovalIds.add(id);
          await widget.notifications.showApproval(_approvalFromMap(approval));
        }
      }
    } catch (_) {
      setStateSafe(() => _error = 'Could not refresh approvals from the API.');
    }
  }

  Future<void> _resolveFromNotification(
    String id,
    String resolution,
    String? resolutionGuidance,
  ) async {
    await _resolveApproval(
      id,
      resolution,
      resolutionGuidance: resolutionGuidance,
    );
  }

  Future<void> _resolveApproval(
    String id,
    String resolution, {
    String? resolutionGuidance,
  }) async {
    setStateSafe(() => _busy = true);
    try {
      final guidance = resolution == 'deny'
          ? _cleanResolutionGuidance(resolutionGuidance)
          : null;
      final body = <String, String>{'resolution': resolution};
      if (guidance != null) body['resolutionGuidance'] = guidance;
      final response = await _request(
        'POST',
        '/v1/mobile/decisions/$id/resolve',
        'mobileDecisionResolve',
        body: body,
      );
      if (response.statusCode >= 400) throw Exception(response.body);
      await _refreshState();
    } catch (_) {
      setStateSafe(
        () => _error = 'Could not send your decision. Please try again.',
      );
    } finally {
      setStateSafe(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    _poller?.cancel();
    _token = null;
    _state = null;
    await _save();
    setStateSafe(() {});
  }

  void setStateSafe(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Future<String> _responseMessage(http.Response response) async {
    try {
      final payload = jsonDecode(response.body);
      if (payload is Map) {
        final message =
            payload['message'] ?? payload['error'] ?? payload['detail'];
        final required = payload['required'];
        final suffix = required is List
            ? ' Required: ${required.join(', ')}.'
            : '';
        if (message != null) return '${message.toString()}$suffix';
      }
    } catch (_) {
      // Fall back to the raw response below.
    }
    return response.body.isNotEmpty
        ? response.body
        : 'HTTP ${response.statusCode}';
  }

  String _cleanError(Object error) {
    final text = error.toString().replaceFirst(RegExp(r'^Exception: ?'), '');
    return text.endsWith('.') ? text : '$text.';
  }

  Approval _approvalFromMap(Map approval) {
    final triggeredPolicies =
        (approval['triggered_policies'] as List?) ??
        (approval['triggeredPolicies'] as List?) ??
        const [];
    Map? firstPolicy;
    for (final item in triggeredPolicies) {
      if (item is Map) {
        firstPolicy = item;
        break;
      }
    }
    final policy =
        approval['primary_policy'] ??
        approval['primaryPolicy'] ??
        approval['policy_title'] ??
        approval['policyTitle'] ??
        firstPolicy?['policy_name'] ??
        firstPolicy?['policyName'] ??
        approval['title'];
    final project =
        approval['project_name']?.toString() ??
        approval['projectName']?.toString() ??
        _projectNameFromPath(
          approval['project_path']?.toString() ??
              approval['projectPath']?.toString(),
        );
    return Approval(
      id: approval['id']?.toString() ?? '',
      title: approval['summary']?.toString() ?? 'OpenLeash approval needed',
      agent:
          approval['agent_name']?.toString() ??
          approval['agentName']?.toString() ??
          'AI agent',
      agentKind:
          approval['agent_kind']?.toString() ??
          approval['agentKind']?.toString(),
      project: project ?? 'Project',
      policy: policy?.toString() ?? 'OpenLeash rule',
      purpose:
          approval['purpose_summary']?.toString() ??
          approval['purposeSummary']?.toString(),
      quote:
          approval['quote']?.toString() ??
          firstPolicy?['explanation']?.toString(),
      context: _contextFromApproval(approval),
      createdAt:
          DateTime.tryParse(
            approval['created_at']?.toString() ??
                approval['createdAt']?.toString() ??
                '',
          ) ??
          DateTime.now(),
    );
  }

  String? _projectNameFromPath(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final normalized = value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? normalized : parts.last;
  }

  List<ApprovalContextLine> _contextFromApproval(Map approval) {
    final raw =
        (approval['recent_context'] as List?) ??
        (approval['recentContext'] as List?) ??
        const [];
    return raw
        .whereType<Map>()
        .map((item) {
          return ApprovalContextLine(
            role: item['role']?.toString() ?? 'context',
            content: item['content']?.toString() ?? '',
          );
        })
        .where((item) => item.content.trim().isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: RefreshIndicator(
              onRefresh: () => _refreshState(showNotifications: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
                children: [
                  _LogoHeader(signedIn: _signedIn, onSignOut: _signOut),
                  SizedBox(height: _signedIn ? 20 : 18),
                  if (_error != null) _ErrorBanner(message: _error!),
                  if (_busy) const LinearProgressIndicator(minHeight: 3),
                  if (!_signedIn) ..._wizard() else ..._approvalHome(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _wizard() {
    return [_signInLanding(), const SizedBox(height: 18)];
  }

  Widget _signInLanding() {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Sign in to OpenLeash',
            style: TextStyle(
              fontSize: 32,
              height: 1.02,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Use an existing OpenLeash Cloud or company account to approve agent actions from your phone.',
            style: TextStyle(
              color: Color(0xff8a909e),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          if (!_customApi) ...[
            _GoogleButton(
              busy: _busy,
              onPressed: () {
                setState(() => _apiController.text = _defaultCloudApiUrl());
                _startSignIn('google');
              },
            ),
            const SizedBox(height: 10),
            _ProviderButton(
              label: 'Sign in with Microsoft',
              mark: 'M',
              busy: _busy && _pendingProvider == 'azure_ad',
              onPressed: () {
                setState(() => _apiController.text = _defaultCloudApiUrl());
                _startSignIn('azure_ad');
              },
            ),
            const SizedBox(height: 10),
            _SecondaryButton(
              label: 'Use company API',
              onPressed: () => setState(() {
                _customApi = true;
                _audience = 'organization';
              }),
            ),
          ],
          if (_customApi) ...[
            _Input(
              controller: _apiController,
              label: 'OpenLeash URL',
              hint: 'https://api.company.com',
            ),
            const SizedBox(height: 16),
            _PrimaryButton(
              label: 'Sign in with company',
              icon: Icons.arrow_forward,
              onPressed: () => _startSignIn(),
            ),
            const SizedBox(height: 10),
            _SecondaryButton(
              label: 'Use OpenLeash Cloud',
              onPressed: () => setState(() {
                _customApi = false;
                _audience = 'individual';
                _apiController.text = _defaultCloudApiUrl();
              }),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _approvalHome() {
    final user =
        (_state?['user'] as Map?)?['name']?.toString() ??
        (_state?['user'] as Map?)?['display_name']?.toString() ??
        (_state?['user'] as Map?)?['displayName']?.toString() ??
        (_state?['user'] as Map?)?['email']?.toString() ??
        'Signed in';
    final organization =
        (_state?['organization'] as Map?)?['name']?.toString() ?? 'OpenLeash';
    final visibleAgents = _agents
        .whereType<Map>()
        .where(_isVisibleAgent)
        .toList();
    final sessionCount = visibleAgents.fold<int>(
      0,
      (count, agent) => count + _agentSessions(agent).length,
    );
    final sessionMetrics = (_state?['sessionMetrics'] as Map?) ?? const {};
    final visibleHistory = _recentActivity
        .whereType<Map>()
        .where(_isInterestingActivity)
        .toList();
    final agentCount = visibleAgents.length;
    return [
      _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 24,
                  backgroundColor: Color(0xffe8f6f1),
                  child: Icon(
                    Icons.verified_user_outlined,
                    color: Color(0xff0e755e),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        organization,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xff8a909e),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _refreshState(showNotifications: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _DashboardMetric(
                    value: '$agentCount',
                    label: agentCount == 1 ? 'agent' : 'agents',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DashboardMetric(
                    value: '${_pendingApprovals.length}',
                    label: 'pending',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DashboardMetric(
                    value: _formatDuration(sessionMetrics['last24h_seconds']),
                    label: '$sessionCount sessions',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (_pendingApprovals.isNotEmpty) ...[
        const _SectionTitle('Pending approvals'),
        const SizedBox(height: 8),
        ..._pendingApprovals.map((item) {
          final approval = _approvalFromMap(item as Map);
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _ApprovalCard(
              approval: approval,
              onAllow: () => _resolveApproval(approval.id, 'allow'),
              onDeny: (guidance) => _resolveApproval(
                approval.id,
                'deny',
                resolutionGuidance: guidance,
              ),
            ),
          );
        }),
      ],
      _ActiveSessionHeader(count: sessionCount),
      const SizedBox(height: 8),
      if (visibleAgents.isEmpty)
        const _EmptyApprovals()
      else ...[
        for (final item in visibleAgents)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _AgentCard(agent: item),
          ),
      ],
      const SizedBox(height: 16),
      const _SectionTitle('History'),
      const SizedBox(height: 8),
      _Panel(
        child: visibleHistory.isEmpty
            ? const Text(
                'No history yet.',
                style: TextStyle(
                  color: Color(0xff8a909e),
                  fontWeight: FontWeight.w700,
                ),
              )
            : Column(
                children: [
                  for (
                    var index = 0;
                    index < visibleHistory.length;
                    index++
                  ) ...[
                    _HistoryRow(item: visibleHistory[index]),
                    if (index != visibleHistory.length - 1)
                      const Divider(height: 18),
                  ],
                ],
              ),
      ),
    ];
  }
}

class ApprovalNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void> Function(
    String id,
    String resolution,
    String? resolutionGuidance,
  )?
  onDecision;

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentSound: true,
      notificationCategories: [
        DarwinNotificationCategory(
          'openleash_approval',
          actions: [
            DarwinNotificationAction.plain(
              'deny',
              'Deny',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.destructive,
              },
            ),
            DarwinNotificationAction.plain('allow', 'Allow'),
          ],
        ),
        DarwinNotificationCategory(
          'openleash_approval_guidance',
          actions: [
            DarwinNotificationAction.plain(
              'deny',
              'Deny',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.destructive,
              },
            ),
            DarwinNotificationAction.text(
              'deny_with_guidance',
              'Guide',
              buttonTitle: 'Deny',
              placeholder: 'Tell the agent what to do instead',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.destructive,
              },
            ),
            DarwinNotificationAction.plain('allow', 'Allow'),
          ],
        ),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        final action = response.actionId;
        if (payload != null && (action == 'allow' || action == 'deny')) {
          onDecision?.call(payload, action!, null);
        }
        if (payload != null && action == 'deny_with_guidance') {
          onDecision?.call(payload, 'deny', response.input);
        }
      },
    );
  }

  Future<void> requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> showApproval(Approval approval) async {
    final supportsGuidance = _supportsAgentGuidance(approval.agentKind);
    final android = AndroidNotificationDetails(
      'openleash_approvals',
      'OpenLeash approvals',
      channelDescription: 'Approve or deny OpenLeash agent actions.',
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.status,
      actions: [
        const AndroidNotificationAction('deny', 'Deny'),
        if (supportsGuidance)
          const AndroidNotificationAction(
            'deny_with_guidance',
            'Guide',
            inputs: <AndroidNotificationActionInput>[
              AndroidNotificationActionInput(
                label: 'Tell the agent what to do instead',
              ),
            ],
          ),
        const AndroidNotificationAction('allow', 'Allow'),
      ],
    );
    final darwin = DarwinNotificationDetails(
      categoryIdentifier: supportsGuidance
          ? 'openleash_approval_guidance'
          : 'openleash_approval',
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      presentBanner: true,
      presentList: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    await _plugin.show(
      id: approval.id.hashCode & 0x7fffffff,
      title: 'Allow ${approval.agent}?',
      body: approval.notificationBody,
      notificationDetails: NotificationDetails(android: android, iOS: darwin),
      payload: approval.id,
    );
  }
}

class Approval {
  Approval({
    required this.id,
    required this.title,
    required this.agent,
    this.agentKind,
    required this.project,
    required this.policy,
    this.purpose,
    this.quote,
    this.context = const [],
    required this.createdAt,
  });

  final String id;
  final String title;
  final String agent;
  final String? agentKind;
  final String project;
  final String policy;
  final String? purpose;
  final String? quote;
  final List<ApprovalContextLine> context;
  final DateTime createdAt;

  String get notificationBody {
    final lines = [
      title,
      if (purpose != null && purpose!.trim().isNotEmpty)
        'Why: ${purpose!.trim()}',
      'Project: $project',
      'Rule: $policy',
      if (quote != null && quote!.trim().isNotEmpty) 'Quote: ${quote!.trim()}',
      if (context.isNotEmpty) 'Context: ${context.last.content}',
    ];
    return lines.join('\n');
  }
}

String? _cleanResolutionGuidance(String? value) {
  final cleaned = (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length > 500 ? cleaned.substring(0, 500) : cleaned;
}

bool _supportsAgentGuidance(String? agentKind) {
  return const {
    'claude-code',
    'codex',
    'openclaw',
    'nanoclaw',
  }.contains(agentKind);
}

class ApprovalContextLine {
  const ApprovalContextLine({required this.role, required this.content});

  final String role;
  final String content;
}

class _LogoHeader extends StatelessWidget {
  const _LogoHeader({required this.signedIn, required this.onSignOut});

  final bool signedIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/openleash-icon.png',
            width: 38,
            height: 38,
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'OpenLeash',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const Spacer(),
        if (signedIn)
          PopupMenuButton<String>(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: 28),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onSelected: (value) {
              if (value == 'sign-out') onSignOut();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'sign-out',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('Sign out'),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xffdde2eb)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 26,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: const Color(0xfff7f8fa),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xffdde2eb)),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xff0f1219),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.onPressed, required this.busy});

  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xff1f1f1f),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: const BorderSide(color: Color(0xffdadce0)),
        ),
        onPressed: busy ? null : onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 30,
              width: 30,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Color(0xffdadce0)),
              ),
              child: const Center(
                child: Text(
                  'G',
                  style: TextStyle(
                    color: Color(0xff4285f4),
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              busy ? 'Opening Google...' : 'Sign in with Google',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.label,
    required this.mark,
    required this.onPressed,
    required this.busy,
  });

  final String label;
  final String mark;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xff1f1f1f),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: const BorderSide(color: Color(0xffdadce0)),
        ),
        onPressed: busy ? null : onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mark,
              style: const TextStyle(
                color: Color(0xff2563eb),
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              busy ? 'Opening...' : label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        side: const BorderSide(color: Color(0xffdde2eb)),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffff2f0),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xffb3261e)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
    );
  }
}

class _ActiveSessionHeader extends StatelessWidget {
  const _ActiveSessionHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            'ACTIVE AGENT SESSIONS ($count)',
            style: const TextStyle(
              color: Color(0xff5c6370),
              fontSize: 13,
              letterSpacing: 2.2,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const Text(
          'Realtime Remote Nodes',
          style: TextStyle(
            color: Color(0xff6e7582),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _DashboardMetric extends StatelessWidget {
  const _DashboardMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xfff4f6fb),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xff8a909e),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyApprovals extends StatelessWidget {
  const _EmptyApprovals();

  @override
  Widget build(BuildContext context) {
    return const _Panel(
      child: Column(
        children: [
          Icon(Icons.computer_rounded, size: 48, color: Color(0xff4f5a6c)),
          SizedBox(height: 12),
          Text(
            'No agents connected yet',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 6),
          Text(
            'Install OpenLeash Client on your Mac or Windows computer. Your agents and approvals will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xff8a909e),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentCard extends StatefulWidget {
  const _AgentCard({required this.agent});

  final Map agent;

  @override
  State<_AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<_AgentCard> {
  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final name = _agentName(agent);
    final kind = _agentKindLabel(agent);
    final status = _agentStatus(agent);
    final summary = _agentSummary(agent);
    final sessions = _agentSessions(agent);
    final primarySession = sessions.isNotEmpty ? sessions.first : null;
    final target = primarySession?['title']?.toString() ?? summary;
    final stream = _sessionStream(primarySession, agent);
    final elapsed = primarySession == null
        ? _relativeTime(_agentActivityAt(agent))
        : _formatDuration(
            primarySession['duration_seconds'] ??
                primarySession['durationSeconds'],
          );
    final syncId = _shortSyncId(primarySession?['session_id'] ?? agent['id']);
    final completedCalls =
        primarySession?['event_count'] ?? primarySession?['eventCount'] ?? 0;
    final nodeCount = _agentNodeCount(agent);
    final tint = _agentTint(status);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: primarySession == null
          ? null
          : () => _openSessionDetail(context, primarySession, name),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: tint.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tint.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tint.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: tint.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.asset(
                      _agentIconAsset(agent),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              kind.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xff006bd6),
                                fontSize: 11,
                                letterSpacing: 1.9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 7),
                            child: Text('•', style: TextStyle(fontSize: 14)),
                          ),
                          Text(
                            'Node : $nodeCount',
                            style: const TextStyle(
                              color: Color(0xff5f6674),
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _AgentStatusPill(status: status),
              ],
            ),
            const SizedBox(height: 22),
            const Divider(height: 1, color: Color(0xffe4e7ee)),
            const SizedBox(height: 18),
            const Text(
              'TARGET GOAL & PURPOSE',
              style: TextStyle(
                color: Color(0xff717886),
                fontSize: 11,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              target,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff151820),
                fontSize: 23,
                height: 1.18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xffe0e4ec)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ACTIVE REMOTE WORKTIME STREAM',
                    style: TextStyle(
                      color: Color(0xff747b88),
                      fontSize: 10,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(top: 7),
                        decoration: BoxDecoration(
                          color: tint.dot,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '“$stream”',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tint.text,
                            fontSize: 16,
                            height: 1.25,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _TinyMeta(label: 'ELAPSED', value: elapsed),
                      ),
                      _TinyMeta(label: 'SYNC ID', value: syncId),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, color: Color(0xffe4e7ee)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: 'Completed calls: ',
                      style: const TextStyle(
                        color: Color(0xff747b88),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      children: [
                        TextSpan(
                          text: '$completedCalls',
                          style: const TextStyle(
                            color: Color(0xff151820),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: primarySession == null
                      ? null
                      : () => _openSessionDetail(context, primarySession, name),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xff4d5563),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    side: const BorderSide(color: Color(0xffdce2eb)),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  icon: const Icon(Icons.shield_outlined, size: 15),
                  label: const Text('LEASH CODE'),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: primarySession == null
                      ? null
                      : () => _openSessionDetail(context, primarySession, name),
                  style: IconButton.styleFrom(
                    side: const BorderSide(color: Color(0xffdce2eb)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: const Icon(Icons.north_east, size: 17),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentStatusPill extends StatelessWidget {
  const _AgentStatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final tint = _agentTint(status);
    return Container(
      constraints: const BoxConstraints(minWidth: 86),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: tint.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: tint.dot,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              _statusCopy(status).toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tint.text,
                fontSize: 10,
                height: 1.05,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyMeta extends StatelessWidget {
  const _TinyMeta({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: '$label: ',
        style: const TextStyle(
          color: Color(0xff747b88),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        children: [
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xff252a33),
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _AgentActionRow extends StatelessWidget {
  const _AgentActionRow({required this.item});

  final Map item;

  @override
  Widget build(BuildContext context) {
    final decision =
        item['resolution']?.toString() ??
        item['decision']?.toString() ??
        'logged';
    final summary = _eventSummary(item);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openEventDetail(context, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _decisionIcon(decision),
              size: 18,
              color: _decisionColor(decision),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff303641),
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_friendlyAction(item)} · ${_relativeTime(item['created_at'] ?? item['createdAt'] ?? item['activity_at'] ?? item['activityAt'])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff8a909e),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xff9aa1ad)),
          ],
        ),
      ),
    );
  }
}

void _openSessionDetail(BuildContext context, Map session, String agentName) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          _SessionDetailPage(session: session, agentName: agentName),
    ),
  );
}

class _SessionDetailPage extends StatelessWidget {
  const _SessionDetailPage({required this.session, required this.agentName});

  final Map session;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    final events = ((session['events'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final mcpServers =
        ((session['mcp_servers'] as List?) ??
                (session['mcpServers'] as List?) ??
                const [])
            .map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList();
    final project =
        _projectNameFromAny(
          session['project_path'] ?? session['projectPath'],
        ) ??
        'No project';
    return Scaffold(
      backgroundColor: const Color(0xffeef1f6),
      appBar: AppBar(
        title: const Text('Session'),
        backgroundColor: const Color(0xffeef1f6),
        foregroundColor: const Color(0xff0f1219),
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session['title']?.toString() ?? 'Agent session',
                        style: const TextStyle(
                          fontSize: 25,
                          height: 1.08,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '$agentName · $project · ${_formatDuration(session['duration_seconds'] ?? session['durationSeconds'])} · ${_formatDateTime(session['last_activity_at'] ?? session['lastActivityAt'])}',
                        style: const TextStyle(
                          color: Color(0xff8a909e),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        session['summary']?.toString() ??
                            'Session captured by OpenLeash.',
                        style: const TextStyle(
                          color: Color(0xff303641),
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _Pill(icon: Icons.folder_outlined, label: project),
                          _Pill(
                            icon: Icons.timer_outlined,
                            label: _formatDuration(
                              session['duration_seconds'] ??
                                  session['durationSeconds'],
                            ),
                          ),
                          _Pill(
                            icon: Icons.account_tree_outlined,
                            label:
                                '${_formatDuration(session['subagent_seconds'] ?? session['subagentSeconds'])} subagents',
                          ),
                          _Pill(
                            icon: Icons.list_alt,
                            label:
                                '${session['event_count'] ?? session['eventCount'] ?? events.length} events',
                          ),
                          _Pill(
                            icon: Icons.pending_actions,
                            label:
                                '${session['approval_count'] ?? session['approvalCount'] ?? 0} approvals',
                          ),
                          for (final server in mcpServers)
                            _Pill(icon: Icons.hub_outlined, label: server),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const _SectionTitle('What happened'),
                const SizedBox(height: 8),
                _Panel(
                  child: events.isEmpty
                      ? const Text(
                          'No event details captured for this session.',
                          style: TextStyle(
                            color: Color(0xff8a909e),
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : Column(
                          children: [
                            for (
                              var index = 0;
                              index < events.length;
                              index++
                            ) ...[
                              _AgentActionRow(item: events[index]),
                              if (index != events.length - 1)
                                const Divider(height: 18),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.item});

  final Map item;

  @override
  Widget build(BuildContext context) {
    final agent =
        item['agent_name']?.toString() ??
        item['agentName']?.toString() ??
        'Agent';
    final summary = _eventSummary(item);
    final decision =
        item['resolution']?.toString() ??
        item['decision']?.toString() ??
        'logged';
    final createdAt = _relativeTime(item['created_at'] ?? item['createdAt']);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openEventDetail(context, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _decisionColor(decision).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _decisionIcon(decision),
                size: 18,
                color: _decisionColor(decision),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$agent · $createdAt',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff8a909e),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Icon(
                Icons.chevron_right,
                color: Color(0xff9aa1ad),
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _openEventDetail(BuildContext context, Map item) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => _EventDetailPage(item: item)));
}

class _EventDetailPage extends StatelessWidget {
  const _EventDetailPage({required this.item});

  final Map item;

  @override
  Widget build(BuildContext context) {
    final agent =
        item['agent_name']?.toString() ??
        item['agentName']?.toString() ??
        item['display_name']?.toString() ??
        item['displayName']?.toString() ??
        'Agent';
    final decision =
        item['resolution']?.toString() ??
        item['decision']?.toString() ??
        'logged';
    final summary = _eventSummary(item);
    final project =
        _projectNameFromAny(item['project_name'] ?? item['projectName']) ??
        _projectNameFromAny(item['project_path'] ?? item['projectPath']) ??
        'No project';
    final createdAt = _formatDateTime(
      item['created_at'] ??
          item['createdAt'] ??
          item['activity_at'] ??
          item['activityAt'],
    );
    final policies =
        ((item['triggered_policies'] as List?) ??
                (item['triggeredPolicies'] as List?) ??
                const [])
            .whereType<Map>()
            .toList();
    final purpose = _eventPurpose(item);
    final prompt = _eventPrompt(item);

    return Scaffold(
      backgroundColor: const Color(0xffeef1f6),
      appBar: AppBar(
        title: const Text('Event details'),
        backgroundColor: const Color(0xffeef1f6),
        foregroundColor: const Color(0xff0f1219),
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _decisionColor(
                                decision,
                              ).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              _decisionIcon(decision),
                              color: _decisionColor(decision),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  summary,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    height: 1.08,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '$agent · $createdAt',
                                  style: const TextStyle(
                                    color: Color(0xff8a909e),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _Pill(icon: Icons.folder_outlined, label: project),
                          _Pill(
                            icon: Icons.bolt_outlined,
                            label: _friendlyAction(item),
                          ),
                          _Pill(icon: Icons.rule_rounded, label: decision),
                        ],
                      ),
                    ],
                  ),
                ),
                if (policies.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const _SectionTitle('Policies'),
                  const SizedBox(height: 8),
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (
                          var index = 0;
                          index < policies.length;
                          index++
                        ) ...[
                          _PolicyDetail(policy: policies[index]),
                          if (index != policies.length - 1)
                            const Divider(height: 20),
                        ],
                      ],
                    ),
                  ),
                ],
                if (purpose != null || prompt != null) ...[
                  const SizedBox(height: 16),
                  const _SectionTitle('Context'),
                  const SizedBox(height: 8),
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (purpose != null) ...[
                          const Text(
                            'Why this happened',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            purpose,
                            style: const TextStyle(
                              color: Color(0xff303641),
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        if (purpose != null && prompt != null)
                          const Divider(height: 24),
                        if (prompt != null) ...[
                          const Text(
                            'Prompt',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            prompt,
                            style: const TextStyle(
                              color: Color(0xff697181),
                              height: 1.35,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PolicyDetail extends StatelessWidget {
  const _PolicyDetail({required this.policy});

  final Map policy;

  @override
  Widget build(BuildContext context) {
    final name =
        policy['policy_name']?.toString() ??
        policy['policyName']?.toString() ??
        'Policy';
    final explanation = policy['explanation']?.toString() ?? '';
    final evidence =
        (policy['evidence'] as List?)
            ?.map((item) => item.toString())
            .toList() ??
        const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        if (explanation.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            explanation,
            style: const TextStyle(
              color: Color(0xff303641),
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (evidence.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final item in evidence)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '"$item"',
                style: const TextStyle(
                  color: Color(0xff697181),
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

String _agentName(Map agent) {
  return agent['display_name']?.toString() ??
      agent['displayName']?.toString() ??
      agent['kind']?.toString() ??
      'Agent';
}

String _agentKindLabel(Map agent) {
  final raw =
      agent['kind']?.toString() ??
      agent['agent_kind']?.toString() ??
      agent['agentKind']?.toString() ??
      _agentName(agent);
  final text = raw.toLowerCase();
  if (text.contains('salesforce')) return 'Salesforce';
  if (text.contains('codex')) return 'Codex';
  if (text.contains('claude')) return 'Claude';
  if (text.contains('cursor')) return 'Cursor';
  if (text.contains('openclaw')) return 'OpenClaw';
  if (text.contains('nanoclaw')) return 'NanoClaw';
  return raw.replaceAll('-', ' ');
}

String _agentIconAsset(Map agent) {
  final text =
      '${agent['kind'] ?? ''} ${agent['agent_kind'] ?? ''} ${agent['agentKind'] ?? ''} ${_agentName(agent)}'
          .toLowerCase();
  if (text.contains('claude') || text.contains('anthropic')) {
    return 'assets/agents/claude.png';
  }
  if (text.contains('codex')) return 'assets/agents/codex.png';
  if (text.contains('openai')) return 'assets/agents/openai.png';
  if (text.contains('openclaw') || text.contains('nanoclaw')) {
    return 'assets/agents/openclaw.png';
  }
  return 'assets/agents/unknown.png';
}

dynamic _agentActivityAt(Map agent) {
  return agent['activity_at'] ??
      agent['activityAt'] ??
      agent['created_at'] ??
      agent['createdAt'] ??
      agent['last_seen_at'] ??
      agent['lastSeenAt'];
}

String _agentStatus(Map agent) {
  return agent['resolution']?.toString() ??
      agent['decision']?.toString() ??
      'active';
}

int _agentNodeCount(Map agent) {
  final sessions = _agentSessions(agent);
  final sessionCount = sessions.length;
  final host = agent['hostname']?.toString();
  final nodes = sessions
      .map((session) => session['hostname']?.toString())
      .where((value) => value != null && value.trim().isNotEmpty)
      .toSet()
      .length;
  if (nodes > 0) return nodes;
  if (sessionCount > 0) return sessionCount;
  return host == null || host.isEmpty ? 0 : 1;
}

String _sessionStream(Map? session, Map agent) {
  final events = ((session?['events'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  final latest = events.isNotEmpty ? events.first : agent;
  final prompt = _eventPrompt(latest);
  if (prompt != null) return _truncate(prompt, 58);
  final purpose = _eventPurpose(latest);
  if (purpose != null) return _truncate(purpose, 58);
  final summary =
      latest['summary']?.toString() ??
      session?['summary']?.toString() ??
      _agentSummary(agent);
  return _truncate(summary, 58);
}

String _shortSyncId(Object? value) {
  final raw = value?.toString() ?? 'local';
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  if (cleaned.isEmpty) return 'LOCAL';
  return cleaned.length <= 8 ? cleaned : cleaned.substring(cleaned.length - 8);
}

String _statusCopy(String status) {
  final value = status.toLowerCase();
  if (value == 'ask') return 'live waiting';
  if (value == 'deny' || value == 'denied') return 'blocked';
  if (value == 'allow' || value == 'approved') return 'live running';
  if (value.contains('upgrade')) return 'upgrading';
  return 'live running';
}

_AgentTint _agentTint(String status) {
  final value = status.toLowerCase();
  if (value == 'ask') {
    return const _AgentTint(
      card: Color(0xfffffcf5),
      surface: Color(0xfffff4dc),
      border: Color(0xffffd58a),
      text: Color(0xffa14b00),
      dot: Color(0xffff9d00),
    );
  }
  if (value == 'deny' || value == 'denied') {
    return const _AgentTint(
      card: Color(0xfffff8f8),
      surface: Color(0xffffecec),
      border: Color(0xffffc8c8),
      text: Color(0xffb3261e),
      dot: Color(0xffd93025),
    );
  }
  return const _AgentTint(
    card: Color(0xfff7fffb),
    surface: Color(0xffe9fff6),
    border: Color(0xff9ee8c1),
    text: Color(0xff047857),
    dot: Color(0xff17c987),
  );
}

class _AgentTint {
  const _AgentTint({
    required this.card,
    required this.surface,
    required this.border,
    required this.text,
    required this.dot,
  });

  final Color card;
  final Color surface;
  final Color border;
  final Color text;
  final Color dot;
}

String _agentSummary(Map agent) {
  final summary =
      agent['short_summary']?.toString() ??
      agent['shortSummary']?.toString() ??
      agent['decision_summary']?.toString() ??
      agent['decisionSummary']?.toString();
  if (summary != null &&
      summary.trim().isNotEmpty &&
      !_isBoringSummary(summary)) {
    return summary;
  }
  final purpose = _eventPurpose(agent);
  if (purpose != null) return purpose;
  final prompt = _eventPrompt(agent);
  if (prompt != null) return 'Prompt: ${_truncate(prompt, 100)}';
  final target = _eventTarget(agent);
  if (target != null) return '${_friendlyAction(agent)} on $target';
  return _friendlyAction(agent);
}

String _friendlyAction(Map agent) {
  final tool = agent['tool_name']?.toString() ?? agent['toolName']?.toString();
  final event =
      agent['event_name']?.toString() ?? agent['eventName']?.toString();
  if (tool != null && tool.isNotEmpty) return 'Using $tool';
  if (event == 'UserPromptSubmit') return 'Reading prompt';
  if (event == 'PreToolUse' || event == 'PostToolUse') return 'Using tool';
  if (event == 'Stop') return 'Session ended';
  return event?.isNotEmpty == true ? event! : 'Connected';
}

String _eventSummary(Map item) {
  final summary = item['summary']?.toString();
  if (summary != null &&
      summary.trim().isNotEmpty &&
      !_isBoringSummary(summary)) {
    return summary.trim();
  }
  final question = item['question']?.toString();
  if (question != null && question.trim().isNotEmpty) return question.trim();
  final purpose = _eventPurpose(item);
  if (purpose != null) return purpose;
  final prompt = _eventPrompt(item);
  if (prompt != null) return 'Prompt: ${_truncate(prompt, 110)}';
  final target = _eventTarget(item);
  if (target != null) return '${_friendlyAction(item)} on $target';
  return _friendlyAction(item);
}

bool _isVisibleAgent(Map item) {
  if (_agentSessions(item).isNotEmpty) return true;
  final event =
      item['event_name']?.toString() ?? item['eventName']?.toString() ?? '';
  if (event == 'Stop') return false;
  final date = DateTime.tryParse(_agentActivityAt(item)?.toString() ?? '');
  if (date == null) return false;
  return DateTime.now().difference(date.toLocal()) <
      const Duration(seconds: 90);
}

bool _isInterestingActivity(Map item) {
  final event =
      item['event_name']?.toString() ?? item['eventName']?.toString() ?? '';
  if (event == 'Stop') return false;
  final summary = item['summary']?.toString();
  if (_isBoringSummary(summary)) return false;
  final decision = item['decision']?.toString();
  final resolution = item['resolution']?.toString();
  if (decision == 'ask' || decision == 'deny' || resolution == 'deny') {
    return true;
  }
  return _triggeredPolicies(item).isNotEmpty;
}

List<Map> _agentSessions(Map item) {
  return ((item['sessions'] as List?) ?? const []).whereType<Map>().toList();
}

bool _isBoringSummary(String? summary) {
  return summary != null &&
      RegExp(
        r'all active policies passed',
        caseSensitive: false,
      ).hasMatch(summary);
}

List<Map> _triggeredPolicies(Map item) {
  return ((item['triggered_policies'] as List?) ??
          (item['triggeredPolicies'] as List?) ??
          const [])
      .whereType<Map>()
      .toList();
}

String? _eventPurpose(Map item) {
  final direct =
      item['purpose_summary']?.toString() ?? item['purposeSummary']?.toString();
  if (direct != null && direct.trim().isNotEmpty) return direct.trim();
  final payload = item['payload'];
  if (payload is Map) {
    final purpose = payload['openleashPurposeSummary']?.toString();
    if (purpose != null && purpose.trim().isNotEmpty) return purpose.trim();
  }
  return null;
}

String? _eventPrompt(Map item) {
  final direct = item['prompt']?.toString();
  if (direct != null && direct.trim().isNotEmpty) return direct.trim();
  final payload = item['payload'];
  if (payload is Map) {
    final prompt = payload['prompt']?.toString();
    if (prompt != null && prompt.trim().isNotEmpty) return prompt.trim();
  }
  return null;
}

String? _eventTarget(Map item) {
  final payload = item['payload'];
  if (payload is! Map) return null;
  final tool = payload['tool'];
  if (tool is! Map) return null;
  final input = tool['input'];
  if (input is! Map) return null;
  final target =
      input['file_path'] ?? input['path'] ?? input['command'] ?? input['url'];
  final value = target?.toString();
  return value == null || value.trim().isEmpty
      ? null
      : _truncate(value.trim(), 80);
}

String? _projectNameFromAny(dynamic raw) {
  final value = raw?.toString();
  if (value == null || value.trim().isEmpty) return null;
  final normalized = value.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final parts = normalized.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? normalized : parts.last;
}

String _relativeTime(dynamic raw) {
  final date = DateTime.tryParse(raw?.toString() ?? '');
  if (date == null) return 'new';
  final diff = DateTime.now().difference(date.toLocal());
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return DateFormat.MMMd().format(date.toLocal());
}

String _formatDateTime(dynamic raw) {
  final date = DateTime.tryParse(raw?.toString() ?? '');
  if (date == null) return 'Unknown time';
  return DateFormat.MMMd().add_jm().format(date.toLocal());
}

String _formatDuration(dynamic raw) {
  final total = (num.tryParse(raw?.toString() ?? '') ?? 0).round();
  if (total < 60) return total > 0 ? '${total}s' : '0s';
  final minutes = total ~/ 60;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest > 0 ? '${hours}h ${rest}m' : '${hours}h';
}

String _truncate(String value, int max) {
  if (value.length <= max) return value;
  return '${value.substring(0, max - 1)}…';
}

Color _decisionColor(String decision) {
  if (decision == 'allow' || decision == 'allowed') {
    return const Color(0xff0e755e);
  }
  if (decision == 'deny' || decision == 'denied') {
    return const Color(0xffb3261e);
  }
  if (decision == 'ask') return const Color(0xffa45f00);
  return const Color(0xff4f5a6c);
}

IconData _decisionIcon(String decision) {
  if (decision == 'allow' || decision == 'allowed') {
    return Icons.check_circle_outline;
  }
  if (decision == 'deny' || decision == 'denied') return Icons.block;
  if (decision == 'ask') return Icons.pending_actions;
  return Icons.history;
}

class _ApprovalCard extends StatefulWidget {
  const _ApprovalCard({
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final Approval approval;
  final VoidCallback onAllow;
  final ValueChanged<String?> onDeny;

  @override
  State<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<_ApprovalCard> {
  final _guidanceController = TextEditingController();
  bool _showGuidance = false;

  @override
  void dispose() {
    _guidanceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    final supportsGuidance = _supportsAgentGuidance(approval.agentKind);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Allow ${approval.agent}?',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            approval.title,
            style: const TextStyle(
              fontSize: 17,
              height: 1.35,
              color: Color(0xff303641),
              fontWeight: FontWeight.w600,
            ),
          ),
          if (approval.purpose?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: 12),
            _PurposeBox(text: approval.purpose!.trim()),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Pill(icon: Icons.folder_outlined, label: approval.project),
              _Pill(icon: Icons.shield_outlined, label: approval.policy),
              _Pill(
                icon: Icons.schedule,
                label: DateFormat.MMMd().add_jm().format(approval.createdAt),
              ),
            ],
          ),
          if ((approval.quote?.trim().isNotEmpty ?? false) ||
              approval.context.isNotEmpty) ...[
            const SizedBox(height: 14),
            _ApprovalContextBox(approval: approval),
          ],
          if (supportsGuidance) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showGuidance = !_showGuidance),
                child: Text(
                  _showGuidance
                      ? 'Hide guidance'
                      : 'Add guidance for the agent',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            if (_showGuidance) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _guidanceController,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Optional: tell the agent what to do instead',
                  filled: true,
                  fillColor: const Color(0xfff7f8fb),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xffe5e7ec)),
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _SecondaryButton(
                  label: 'Deny',
                  onPressed: () => widget.onDeny(_guidanceController.text),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PrimaryButton(
                  label: 'Allow',
                  icon: Icons.check,
                  onPressed: widget.onAllow,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ApprovalContextBox extends StatelessWidget {
  const _ApprovalContextBox({required this.approval});

  final Approval approval;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xfff7f8fb),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xffe3e7ef)),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: const Text(
            'More context',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: approval.quote == null || approval.quote!.trim().isEmpty
              ? null
              : Text(
                  '"${approval.quote!.trim()}"',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xff555d6b),
                    fontWeight: FontWeight.w700,
                  ),
                ),
          children: [
            if (approval.quote != null && approval.quote!.trim().isNotEmpty)
              _ContextQuote(text: approval.quote!.trim()),
            if (approval.context.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final item in approval.context) _ContextLine(line: item),
            ],
          ],
        ),
      ),
    );
  }
}

class _PurposeBox extends StatelessWidget {
  const _PurposeBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff7f8fb),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xffe3e7ef)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why now',
            style: TextStyle(
              color: Color(0xff8a909e),
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xff303641),
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextQuote extends StatelessWidget {
  const _ContextQuote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '"$text"',
        style: const TextStyle(
          color: Color(0xff2f3541),
          fontSize: 15,
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ContextLine extends StatelessWidget {
  const _ContextLine({required this.line});

  final ApprovalContextLine line;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              line.role,
              style: const TextStyle(
                color: Color(0xff697181),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.content,
              style: const TextStyle(
                color: Color(0xff303641),
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xfff1f3f6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xff4a5160)),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xff4a5160),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
