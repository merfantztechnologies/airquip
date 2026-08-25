/**
 * Admin entry points for Geotab integration setup and manual operations.
 */
public with sharing class GeotabIntegrationController {

  public class ConnectionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public String databaseName;
  }

  public class SyncStateResult {
    @AuraEnabled public String lastSyncStatus;
    @AuraEnabled public DateTime lastSyncDateTime;
    @AuraEnabled public String lastErrorMessage;
    @AuraEnabled public Boolean integrationActive;
  }

  @AuraEnabled
  public static ConnectionResult testConnection() {
    ConnectionResult result = new ConnectionResult();
    try {
      GeotabApiService.SessionCredentials session = GeotabApiService.authenticate();
      result.success = true;
      result.databaseName = session.database;
      result.message = 'Successfully authenticated with Geotab.';
    } catch (Exception ex) {
      result.success = false;
      result.message = ex.getMessage();
    }
    return result;
  }

  @AuraEnabled
  public static SyncStateResult getSyncState() {
    Geotab_Sync_State__c state = GeotabApiService.getSyncState();
    SyncStateResult result = new SyncStateResult();
    result.lastSyncStatus = state.Last_Sync_Status__c;
    result.lastSyncDateTime = state.Last_Sync_DateTime__c;
    result.lastErrorMessage = state.Last_Error_Message__c;
    result.integrationActive = GeotabApiService.isIntegrationActive();
    return result;
  }

  @AuraEnabled
  public static String runLocationSyncNow() {
    if (!GeotabApiService.isIntegrationActive()) {
      throw new AuraHandledException('Geotab integration is disabled. Enable it in Geotab Integration Config metadata.');
    }
    System.enqueueJob(new GeotabLocationSyncQueueable());
    return 'Location sync queued.';
  }

  @AuraEnabled
  public static String runDeviceSyncNow() {
    if (!GeotabApiService.isIntegrationActive()) {
      throw new AuraHandledException('Geotab integration is disabled. Enable it in Geotab Integration Config metadata.');
    }
    Geotab_Integration_Config__mdt config = GeotabApiService.getActiveConfig();
    Integer batchSize = config != null && config.Device_Sync_Batch_Size__c != null
      ? Integer.valueOf(config.Device_Sync_Batch_Size__c.intValue())
      : 50;
    Database.executeBatch(new GeotabDeviceSyncBatch(), batchSize);
    return 'Device sync batch started.';
  }

  @AuraEnabled
  public static String scheduleLocationSync() {
    if (!GeotabApiService.isIntegrationActive()) {
      throw new AuraHandledException('Geotab integration is disabled. Enable it in Geotab Integration Config metadata.');
    }
    GeotabLocationSyncScheduler.scheduleFromConfig();
    return 'Location sync scheduler configured.';
  }

  @AuraEnabled
  public static String stopLocationSync() {
    GeotabLocationSyncScheduler.abortExistingJobs();
    return 'Location sync scheduler stopped.';
  }

  @AuraEnabled
  public static String scheduleDeviceSync() {
    if (!GeotabApiService.isIntegrationActive()) {
      throw new AuraHandledException('Geotab integration is disabled. Enable it in Geotab Integration Config metadata.');
    }
    GeotabDeviceSyncScheduler.scheduleHourly();
    return 'Device sync scheduled to run every hour.';
  }

  @AuraEnabled
  public static String stopDeviceSync() {
    GeotabDeviceSyncScheduler.abortExistingJobs();
    return 'Device sync scheduler stopped.';
  }
}