// Copyright 2021 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:cocoon_scheduler/scheduler.dart';
import 'package:cocoon_service/src/model/appengine/commit.dart';
import 'package:cocoon_service/src/model/appengine/task.dart';
import 'package:cocoon_service/src/model/github/checks.dart' as cocoon_github;
import 'package:cocoon_service/src/model/luci/buildbucket.dart';
import 'package:cocoon_service/src/service/cache_service.dart';
import 'package:cocoon_service/src/service/datastore.dart';
import 'package:cocoon_service/src/service/github_checks_service.dart';
import 'package:cocoon_service/src/service/luci.dart';
import 'package:cocoon_service/src/service/scheduler.dart';
import 'package:gcloud/db.dart' as gcloud_db;
import 'package:gcloud/db.dart';
import 'package:github/github.dart';
import 'package:googleapis/bigquery/v2.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import '../model/github/checks_test_data.dart';
import '../src/datastore/fake_config.dart';
import '../src/datastore/fake_datastore.dart';
import '../src/request_handling/fake_http.dart';
import '../src/request_handling/fake_logging.dart';
import '../src/service/fake_github_service.dart';
import '../src/service/fake_luci_build_service.dart';
import '../src/utilities/mocks.dart';

const String singleCiYaml = '''
enabled_branches:
  - master
targets:
  - name: A
    builder: Linux A
    postsubmit: true
    presubmit: true
  - name: B
    builder: Linux B
    enabled_branches:
      - stable
    postsubmit: true
    presubmit: true
''';

void main() {
  CacheService cache;
  FakeConfig config;
  FakeDatastoreDB db;
  FakeHttpClient httpClient;
  MockGithubChecksUtil mockGithubChecksUtil;
  Scheduler scheduler;

  Commit shaToCommit(String sha, {String branch = 'master'}) {
    return Commit(
      key: db.emptyKey.append(Commit, id: 'flutter/flutter/$branch/$sha'),
      sha: sha,
      branch: branch,
      timestamp: int.parse(sha),
    );
  }

  group('Scheduler', () {
    setUp(() {
      final MockTabledataResourceApi tabledataResourceApi = MockTabledataResourceApi();
      when(tabledataResourceApi.insertAll(any, any, any, any)).thenAnswer((_) {
        return Future<TableDataInsertAllResponse>.value(null);
      });

      cache = CacheService(inMemory: true);
      db = FakeDatastoreDB();
      config = FakeConfig(tabledataResourceApi: tabledataResourceApi, dbValue: db, githubService: FakeGithubService());
      httpClient = FakeHttpClient(onIssueRequest: (FakeHttpClientRequest request) {
        if (request.uri.path.contains('.ci.yaml')) {
          httpClient.request.response.body = singleCiYaml;
        } else {
          throw Exception('Failed to find ${request.uri.path}');
        }
      });

      mockGithubChecksUtil = MockGithubChecksUtil();
      scheduler = Scheduler(
        cache: cache,
        config: config,
        datastoreProvider: (DatastoreDB db) => DatastoreService(db, 2),
        githubChecksService: GithubChecksService(config, githubChecksUtil: mockGithubChecksUtil),
        httpClientProvider: () => httpClient,
        luciBuildService: FakeLuciBuildService(
          config,
          githubChecksUtil: mockGithubChecksUtil,
        ),
      );
      scheduler.setLogger(FakeLogging());

      when(mockGithubChecksUtil.createCheckRun(any, any, any, any)).thenAnswer((_) async {
        return CheckRun.fromJson(const <String, dynamic>{
          'id': 1,
          'started_at': '2020-05-10T02:49:31Z',
          'check_suite': <String, dynamic>{'id': 2}
        });
      });
    });

    group('add commits', () {
      List<Commit> createCommitList(
        List<String> shas, {
        String repo = 'flutter',
      }) {
        return List<Commit>.generate(
            shas.length,
            (int index) => Commit(
                  author: 'Username',
                  authorAvatarUrl: 'http://example.org/avatar.jpg',
                  branch: 'master',
                  key: db.emptyKey.append(Commit, id: 'flutter/$repo/master/${shas[index]}'),
                  message: 'commit message',
                  repository: 'flutter/$repo',
                  sha: shas[index],
                  timestamp: DateTime.fromMillisecondsSinceEpoch(int.parse(shas[index])).millisecondsSinceEpoch,
                ));
      }

      test('succeeds when GitHub returns no commits', () async {
        await scheduler.addCommits(<Commit>[]);
        expect(db.values, isEmpty);
      });

      test('inserts all relevant fields of the commit', () async {
        config.flutterBranchesValue = <String>['master'];
        expect(db.values.values.whereType<Commit>().length, 0);
        await scheduler.addCommits(createCommitList(<String>['1']));
        expect(db.values.values.whereType<Commit>().length, 1);
        final Commit commit = db.values.values.whereType<Commit>().single;
        expect(commit.repository, 'flutter/flutter');
        expect(commit.branch, 'master');
        expect(commit.sha, '1');
        expect(commit.timestamp, 1);
        expect(commit.author, 'Username');
        expect(commit.authorAvatarUrl, 'http://example.org/avatar.jpg');
        expect(commit.message, 'commit message');
      });

      test('skips scheduling for unsupported repos', () async {
        config.flutterBranchesValue = <String>['master'];
        await scheduler.addCommits(createCommitList(<String>['1'], repo: 'not-supported'));
        expect(db.values.values.whereType<Commit>().length, 0);
      });

      test('skips commits for which transaction commit fails', () async {
        config.flutterBranchesValue = <String>['master'];

        // Existing commits should not be duplicated.
        final Commit commit = shaToCommit('1');
        db.values[commit.key] = commit;

        db.onCommit = (List<gcloud_db.Model<dynamic>> inserts, List<gcloud_db.Key<dynamic>> deletes) {
          if (inserts.whereType<Commit>().where((Commit commit) => commit.sha == '3').isNotEmpty) {
            throw StateError('Commit failed');
          }
        };
        // Commits are expect from newest to oldest timestamps
        await scheduler.addCommits(createCommitList(<String>['2', '3', '4']));
        expect(db.values.values.whereType<Commit>().length, 3);
        // The 2 new commits are scheduled tasks, existing commit has none.
        expect(db.values.values.whereType<Task>().length, 2 * 5);
        // Check commits were added, but 3 was not
        expect(db.values.values.whereType<Commit>().map<String>(toSha), containsAll(<String>['1', '2', '4']));
        expect(db.values.values.whereType<Commit>().map<String>(toSha), isNot(contains('3')));
      });

      test('skips commits for which task transaction fails', () async {
        config.flutterBranchesValue = <String>['master'];

        // Existing commits should not be duplicated.
        final Commit commit = shaToCommit('1');
        db.values[commit.key] = commit;

        db.onCommit = (List<gcloud_db.Model<dynamic>> inserts, List<gcloud_db.Key<dynamic>> deletes) {
          if (inserts.whereType<Task>().where((Task task) => task.createTimestamp == 3).isNotEmpty) {
            throw StateError('Task failed');
          }
        };
        // Commits are expect from newest to oldest timestamps
        await scheduler.addCommits(createCommitList(<String>['2', '3', '4']));
        expect(db.values.values.whereType<Commit>().length, 3);
        // The 2 new commits are scheduled tasks, existing commit has none.
        expect(db.values.values.whereType<Task>().length, 2 * 5);
        // Check commits were added, but 3 was not
        expect(db.values.values.whereType<Commit>().map<String>(toSha), containsAll(<String>['1', '2', '4']));
        expect(db.values.values.whereType<Commit>().map<String>(toSha), isNot(contains('3')));
      });
    });

    group('add pull request', () {
      test('creates expected commit', () async {
        final PullRequest mergedPr = createPullRequest();
        await scheduler.addPullRequest(mergedPr);

        expect(db.values.values.whereType<Commit>().length, 1);
        final Commit commit = db.values.values.whereType<Commit>().single;
        expect(commit.repository, 'flutter/flutter');
        expect(commit.branch, 'master');
        expect(commit.sha, 'abc');
        expect(commit.timestamp, 1);
        expect(commit.author, 'dash');
        expect(commit.authorAvatarUrl, 'dashatar');
        expect(commit.message, 'example message');
      });

      test('schedules tasks against merged PRs', () async {
        final PullRequest mergedPr = createPullRequest();
        await scheduler.addPullRequest(mergedPr);

        expect(db.values.values.whereType<Commit>().length, 1);
        expect(db.values.values.whereType<Task>().length, 5);
      });

      test('does not schedule tasks against non-merged PRs', () async {
        final PullRequest notMergedPr = createPullRequest(merged: false);
        await scheduler.addPullRequest(notMergedPr);

        expect(db.values.values.whereType<Commit>().map<String>(toSha).length, 0);
        expect(db.values.values.whereType<Task>().length, 0);
      });

      test('does not schedule tasks against already added PRs', () async {
        // Existing commits should not be duplicated.
        final Commit commit = shaToCommit('1');
        db.values[commit.key] = commit;

        final PullRequest alreadyLandedPr = createPullRequest(mergedCommitSha: '1');
        await scheduler.addPullRequest(alreadyLandedPr);

        expect(db.values.values.whereType<Commit>().map<String>(toSha).length, 1);
        // No tasks should be scheduled as that is done on commit insert.
        expect(db.values.values.whereType<Task>().length, 0);
      });

      test('creates expected commit from release branch PR', () async {
        final PullRequest mergedPr = createPullRequest(branch: '1.26');
        await scheduler.addPullRequest(mergedPr);

        expect(db.values.values.whereType<Commit>().length, 1);
        final Commit commit = db.values.values.whereType<Commit>().single;
        expect(commit.repository, 'flutter/flutter');
        expect(commit.branch, '1.26');
        expect(commit.sha, 'abc');
        expect(commit.timestamp, 1);
        expect(commit.author, 'dash');
        expect(commit.authorAvatarUrl, 'dashatar');
        expect(commit.message, 'example message');
      });
    });

    group('process check run', () {
      test('rerequested triggers triggers a luci build', () async {
        when(mockGithubChecksUtil.createCheckRun(any, any, any, any)).thenAnswer((_) async {
          return CheckRun.fromJson(const <String, dynamic>{
            'id': 1,
            'started_at': '2020-05-10T02:49:31Z',
            'check_suite': <String, dynamic>{'id': 2}
          });
        });
        final cocoon_github.CheckRunEvent checkRunEvent = cocoon_github.CheckRunEvent.fromJson(
          jsonDecode(checkRunString) as Map<String, dynamic>,
        );
        expect(await scheduler.processCheckRun(checkRunEvent), true);
      });
    });

    group('presubmit', () {
      test('adds both try_builders and .ci.yaml builds', () async {
        final List<LuciBuilder> presubmitBuilders =
            await scheduler.getPresubmitBuilders(commit: Commit(repository: config.flutterSlug.fullName), prNumber: 42);
        expect(presubmitBuilders.map((LuciBuilder builder) => builder.name).toList(),
            <String>['Linux', 'Mac', 'Windows', 'Linux Coverage', 'Linux A']);
      });

      test('adds only .ci.yaml builds', () async {
        config.luciBuildersValue = <LuciBuilder>[];
        final List<LuciBuilder> presubmitBuilders =
            await scheduler.getPresubmitBuilders(commit: Commit(repository: config.flutterSlug.fullName), prNumber: 42);
        expect(presubmitBuilders.map((LuciBuilder builder) => builder.name).toList(), <String>['Linux A']);
      });

      test('gets only enabled .ci.yaml builds', () async {
        httpClient = FakeHttpClient(onIssueRequest: (FakeHttpClientRequest request) {
          if (request.uri.path.contains('.ci.yaml')) {
            httpClient.request.response.body = '''
enabled_branches:
  - master
targets:
  - name: A
    builder: Linux A
    presubmit: true
  - name: B
    builder: Linux B
    enabled_branches:
      - stable
    presubmit: true
  - name: C
    builder: Linux C
    enabled_branches:
      - master
    presubmit: true
          ''';
          } else {
            throw Exception('Failed to find ${request.uri.path}');
          }
        });
        config.luciBuildersValue = <LuciBuilder>[];
        final List<LuciBuilder> presubmitBuilders =
            await scheduler.getPresubmitBuilders(commit: Commit(repository: config.flutterSlug.fullName), prNumber: 42);
        expect(presubmitBuilders.map((LuciBuilder builder) => builder.name).toList(),
            containsAll(<String>['Linux A', 'Linux C']));
      });

      test('triggers expected presubmit build checks', () async {
        await scheduler.triggerPresubmitTargets(
          branch: config.defaultBranch,
          prNumber: 42,
          slug: config.flutterSlug,
          commitSha: 'abc',
        );
        expect(verify(mockGithubChecksUtil.createCheckRun(any, any, captureAny, 'abc')).captured,
            <dynamic>['ci.yaml validation', 'Linux', 'Mac', 'Windows', 'Linux Coverage', 'Linux A']);
      });

      test('ci.yaml validation passes with default config', () async {
        await scheduler.triggerPresubmitTargets(
          branch: config.defaultBranch,
          prNumber: 42,
          slug: config.flutterSlug,
          commitSha: 'abc',
        );
        expect(
            verify(mockGithubChecksUtil.updateCheckRun(any, any, any,
                    status: captureAnyNamed('status'),
                    conclusion: captureAnyNamed('conclusion'),
                    output: anyNamed('output')))
                .captured,
            <dynamic>[CheckRunStatus.completed, CheckRunConclusion.success]);
      });

      test('ci.yaml validation fails with empty config', () async {
        httpClient = FakeHttpClient(onIssueRequest: (FakeHttpClientRequest request) {
          if (request.uri.path.contains('.ci.yaml')) {
            httpClient.request.response.body = '';
          } else {
            throw Exception('Failed to find ${request.uri.path}');
          }
        });
        await scheduler.triggerPresubmitTargets(
          branch: config.defaultBranch,
          prNumber: 42,
          slug: config.flutterSlug,
          commitSha: 'abc',
        );
        expect(
            verify(mockGithubChecksUtil.updateCheckRun(any, any, any,
                    status: captureAnyNamed('status'),
                    conclusion: captureAnyNamed('conclusion'),
                    output: anyNamed('output')))
                .captured,
            <dynamic>[CheckRunStatus.completed, CheckRunConclusion.failure]);
      });

      test('ci.yaml validation fails with config with unknown dependencies', () async {
        httpClient = FakeHttpClient(onIssueRequest: (FakeHttpClientRequest request) {
          if (request.uri.path.contains('.ci.yaml')) {
            httpClient.request.response.body = '''
enabled_branches:
  - master
targets:
  - name: A
    builder: Linux A
    dependencies:
      - B
          ''';
          } else {
            throw Exception('Failed to find ${request.uri.path}');
          }
        });
        await scheduler.triggerPresubmitTargets(
          branch: config.defaultBranch,
          prNumber: 42,
          slug: config.flutterSlug,
          commitSha: 'abc',
        );
        expect(
            verify(mockGithubChecksUtil.updateCheckRun(any, any, any,
                    status: anyNamed('status'), conclusion: anyNamed('conclusion'), output: captureAnyNamed('output')))
                .captured
                .first
                .text,
            'FormatException: ERROR: A depends on B which does not exist');
      });

      test('retries only triggers failed builds only', () async {
        final MockBuildBucketClient mockBuildbucket = MockBuildBucketClient();
        scheduler = Scheduler(
          cache: cache,
          config: config,
          datastoreProvider: (DatastoreDB db) => DatastoreService(db, 2),
          githubChecksService: GithubChecksService(config, githubChecksUtil: mockGithubChecksUtil),
          httpClientProvider: () => httpClient,
          luciBuildService: FakeLuciBuildService(
            config,
            githubChecksUtil: mockGithubChecksUtil,
            buildbucket: mockBuildbucket,
          ),
        );
        when(mockBuildbucket.batch(any)).thenAnswer((_) async => BatchResponse(
              responses: <Response>[
                Response(
                  searchBuilds: SearchBuildsResponse(
                    builds: <Build>[
                      createBuild(name: 'Linux', id: 1000),
                      createBuild(name: 'Linux Coverage', id: 2000),
                      createBuild(name: 'Mac', id: 3000, status: Status.scheduled),
                      createBuild(name: 'Windows', id: 4000, status: Status.started),
                      createBuild(name: 'Linux A', id: 5000, status: Status.failure)
                    ],
                  ),
                ),
              ],
            ));
        scheduler.setLogger(FakeLogging());
        // Only Linux A should be retried
        final Map<String, CheckRun> checkRuns = <String, CheckRun>{
          'Linux': createCheckRun(name: 'Linux', id: 100),
          'Linux Coverage': createCheckRun(name: 'Linux Coverage', id: 200),
          'Mac': createCheckRun(name: 'Mac', id: 300, status: CheckRunStatus.queued),
          'Windows': createCheckRun(name: 'Windows', id: 400, status: CheckRunStatus.inProgress),
          'Linux A': createCheckRun(name: 'Linux A', id: 500),
        };
        when(mockGithubChecksUtil.allCheckRuns(any, any)).thenAnswer((_) async {
          return checkRuns;
        });

        final cocoon_github.CheckSuiteEvent checkSuiteEvent = cocoon_github.CheckSuiteEvent.fromJson(
            jsonDecode(checkSuiteTemplate('rerequested')) as Map<String, dynamic>);
        await scheduler.retryPresubmitTargets(
            prNumber: 42, slug: config.flutterSlug, commitSha: 'abc', checkSuiteEvent: checkSuiteEvent);
        final List<dynamic> retriedBuildRequests = verify(mockBuildbucket.scheduleBuild(captureAny)).captured;
        expect(retriedBuildRequests.length, 1);
        final ScheduleBuildRequest retryRequest = retriedBuildRequests.first as ScheduleBuildRequest;
        expect(retryRequest.builderId.builder, 'Linux A');
      });
    });

    group('postsubmit', () {
      test('adds both prod_builders and .ci.yaml builds', () async {
        final Commit commit = Commit(repository: config.flutterSlug.fullName);
        final SchedulerConfig schedulerConfig = await scheduler.getSchedulerConfig(commit);
        final List<LuciBuilder> postsubmitBuilders = await scheduler.getPostSubmitBuilders(commit, schedulerConfig);
        expect(postsubmitBuilders.map((LuciBuilder builder) => builder.name).toList(),
            <String>['Linux', 'Mac', 'Windows', 'Linux Coverage', 'Linux A']);
      });
    });
  });
}

Build createBuild({String name, int id = 1000, Status status = Status.success, String bucket = 'try'}) {
  return Build(
    id: id,
    builderId: BuilderId(
      project: 'flutter',
      bucket: bucket,
      builder: name,
    ),
    status: status,
  );
}

CheckRun createCheckRun({String name, int id, CheckRunStatus status = CheckRunStatus.completed}) {
  final int externalId = id * 2;
  final String checkRunJson =
      '{"name": "$name", "id": $id, "external_id": "{$externalId}", "status": "$status", "started_at": "2020-05-10T02:49:31Z", "head_sha": "the_sha", "check_suite": {"id": 456}}';
  return CheckRun.fromJson(jsonDecode(checkRunJson) as Map<String, dynamic>);
}

PullRequest createPullRequest({
  int id = 789,
  String branch = 'master',
  String repo = 'flutter',
  String authorLogin = 'dash',
  String authorAvatar = 'dashatar',
  String title = 'example message',
  int number = 123,
  DateTime mergedAt,
  String mergedCommitSha = 'abc',
  bool merged = true,
}) {
  mergedAt ??= DateTime.fromMillisecondsSinceEpoch(1);
  return PullRequest(
    id: id,
    title: title,
    number: number,
    mergedAt: mergedAt,
    base: PullRequestHead(
        ref: branch,
        repo: Repository(
          fullName: 'flutter/$repo',
          name: repo,
        )),
    user: User(
      login: authorLogin,
      avatarUrl: authorAvatar,
    ),
    mergeCommitSha: mergedCommitSha,
    merged: merged,
  );
}

String toSha(Commit commit) => commit.sha;

int toTimestamp(Commit commit) => commit.timestamp;
