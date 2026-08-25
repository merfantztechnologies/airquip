/**
 * Low-level Geotab MyGeotab JSON-RPC API client.
 * Username/password are stored in Named Credential Geotab_API (External Credential Geotab_API_Auth).
 * Sync options remain in Geotab_Integration_Config__mdt (selected by Geotab Sync State).
 */
public with sharing class GeotabApiService {

  public static final String NAMED_CREDENTIAL = 'callout:Geotab_API';
  public static final String API_PATH = '/apiv1';
  public static final String CONFIG_RECORD = 'Default';

  @TestVisible
  private static String testConfigDeveloperName;
  public static final Integer SESSION_TTL_MINUTES = 25;

  @TestVisible
  private static final String NC_USERNAME = '{!$Credential.Username}';
  @TestVisible
  private static final String NC_PASSWORD = '{!$Credential.Password}';

  @TestVisible
  private static Geotab_Integration_Config__mdt testConfig;

  @TestVisible
  private static Geotab_Sync_State__c testSyncState;

  public class GeotabApiException extends Exception {}

  public class FeedResult {
    public List<Object> data = new List<Object>();
    public String toVersion;
  }

  public class SessionCredentials {
    public String sessionId;
    public String database;
    public String userName;
  }

  public static Geotab_Integration_Config__mdt getConfig() {
    if (Test.isRunningTest() && testConfig != null) {
      return testConfig;
    }
    String developerName = getActiveConfigDeveloperName();
    List<Geotab_Integration_Config__mdt> rows = [
      SELECT
        DeveloperName,
        Database_Name__c,
        Is_Enabled__c,
        Sync_Interval_Seconds__c,
        Device_Sync_Enabled__c,
        Device_Sync_Batch_Size__c,
        Create_Location_History__c,
        Location_History_Interval_Minutes__c,
        Status__c
      FROM Geotab_Integration_Config__mdt
      WHERE DeveloperName = :developerName
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  public static String getActiveConfigDeveloperName() {
    if (Test.isRunningTest() && testConfigDeveloperName != null) {
      return testConfigDeveloperName;
    }
    Geotab_Sync_State__c state = getSyncState();
    return String.isNotBlank(state.Active_Config_Developer_Name__c)
      ? state.Active_Config_Developer_Name__c
      : CONFIG_RECORD;
  }

  public static Geotab_Integration_Config__mdt getActiveConfig() {
    Geotab_Integration_Config__mdt config = getConfig();
    if (config == null || config.Is_Enabled__c != true || config.Status__c != 'Active') {
      return null;
    }
    return config;
  }

  public static Boolean isIntegrationActive() {
    return getActiveConfig() != null;
  }

  public static SessionCredentials authenticate() {
    return authenticate(true);
  }

  private static SessionCredentials authenticate(Boolean shouldCacheSession) {
    Geotab_Integration_Config__mdt config = getConfig();
    Map<String, Object> params = new Map<String, Object>{
      'userName' => resolveCredentialUsername(),
      'password' => resolveCredentialPassword()
    };
    if (config != null && String.isNotBlank(config.Database_Name__c)) {
      params.put('database', config.Database_Name__c);
    }

    Map<String, Object> result = (Map<String, Object>) invoke('Authenticate', params, null);
    Map<String, Object> credentials = (Map<String, Object>) result.get('credentials');
    if (credentials == null) {
      throw new GeotabApiException('Geotab authentication did not return credentials.');
    }

    SessionCredentials session = new SessionCredentials();
    session.sessionId = (String) credentials.get('sessionId');
    session.database = (String) credentials.get('database');
    session.userName = (String) credentials.get('userName');
    if (shouldCacheSession) {
      cacheSession(session);
    }
    return session;
  }

  public static SessionCredentials getOrCreateSession() {
    Geotab_Sync_State__c state = getSyncState();
    if (state.Session_Id__c != null
        && state.Session_Expires_At__c != null
        && state.Session_Expires_At__c > System.now()) {
      SessionCredentials session = new SessionCredentials();
      session.sessionId = state.Session_Id__c;
      session.database = state.Session_Database__c;
      session.userName = state.Session_User_Name__c;
      return session;
    }
    return authenticate(true);
  }

  public static FeedResult getFeed(String typeName, String fromVersion) {
    Geotab_Sync_State__c state = getSyncState();
    Boolean shouldCacheSession = false;
    SessionCredentials session;
    if (state.Session_Id__c != null
        && state.Session_Expires_At__c != null
        && state.Session_Expires_At__c > System.now()) {
      session = new SessionCredentials();
      session.sessionId = state.Session_Id__c;
      session.database = state.Session_Database__c;
      session.userName = state.Session_User_Name__c;
    } else {
      session = authenticate(false);
      shouldCacheSession = true;
    }
    Map<String, Object> params = new Map<String, Object>{
      'typeName' => typeName,
      'credentials' => buildCredentialMap(session),
      'fromVersion' => String.isBlank(fromVersion) ? '0' : fromVersion
    };

    Map<String, Object> result = (Map<String, Object>) invoke('GetFeed', params, session);
    FeedResult feed = new FeedResult();
    if (result.containsKey('data') && result.get('data') != null) {
      feed.data = (List<Object>) result.get('data');
    }
    feed.toVersion = result.containsKey('toVersion')
      ? String.valueOf(result.get('toVersion'))
      : fromVersion;
    if (shouldCacheSession) {
      cacheSession(session);
    }
    return feed;
  }

  public static Object invoke(String method, Map<String, Object> params, SessionCredentials session) {
    Map<String, Object> body = new Map<String, Object>{
      'method' => method,
      'params' => params == null ? new Map<String, Object>() : params
    };

    HttpRequest req = new HttpRequest();
    req.setEndpoint(NAMED_CREDENTIAL + API_PATH);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);
    req.setBody(JSON.serialize(body));

    HttpResponse res = new Http().send(req);
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw new GeotabApiException(
        'Geotab HTTP ' + res.getStatusCode() + ': ' + truncate(res.getBody(), 1000)
      );
    }

    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    if (payload.containsKey('error') && payload.get('error') != null) {
      throw new GeotabApiException('Geotab API error: ' + JSON.serialize(payload.get('error')));
    }
    return payload.get('result');
  }

  @TestVisible
  private static String resolveCredentialUsername() {
    return Test.isRunningTest() ? 'user@test.com' : NC_USERNAME;
  }

  @TestVisible
  private static String resolveCredentialPassword() {
    return Test.isRunningTest() ? 'pass' : NC_PASSWORD;
  }

  private static Map<String, Object> buildCredentialMap(SessionCredentials session) {
    return new Map<String, Object>{
      'sessionId' => session.sessionId,
      'database' => session.database,
      'userName' => session.userName
    };
  }

  private static void cacheSession(SessionCredentials session) {
    Geotab_Sync_State__c state = getSyncState();
    state.Session_Id__c = session.sessionId;
    state.Session_Database__c = session.database;
    state.Session_User_Name__c = session.userName;
    state.Session_Expires_At__c = System.now().addMinutes(SESSION_TTL_MINUTES);
    upsertSyncState(state);
  }

  public static Geotab_Sync_State__c getSyncState() {
    if (Test.isRunningTest() && testSyncState != null) {
      return testSyncState;
    }
    Geotab_Sync_State__c state = Geotab_Sync_State__c.getOrgDefaults();
    if (state == null) {
      state = new Geotab_Sync_State__c(SetupOwnerId = UserInfo.getOrganizationId());
    }
    return state;
  }

  public static void upsertSyncState(Geotab_Sync_State__c state) {
    if (Test.isRunningTest()) {
      testSyncState = state;
      return;
    }
    upsert state;
  }

  public static void updateSyncStatus(String status, String errorMessage) {
    Geotab_Sync_State__c state = getSyncState();
    state.Last_Sync_Status__c = status;
    state.Last_Sync_DateTime__c = System.now();
    state.Last_Error_Message__c = errorMessage;
    upsertSyncState(state);
  }

  private static String truncate(String value, Integer maxLen) {
    if (value == null) {
      return null;
    }
    return value.length() > maxLen ? value.substring(0, maxLen) : value;
  }
}