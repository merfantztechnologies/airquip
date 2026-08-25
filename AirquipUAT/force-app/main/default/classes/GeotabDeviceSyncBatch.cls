/**
 * Upserts FieldAX Vehicle records from Geotab Device feed.
 */
public class GeotabDeviceSyncBatch implements Database.Batchable<Object>, Database.AllowsCallouts, Database.Stateful {

  private String feedVersion;
  private Integer processedCount = 0;

  public Iterable<Object> start(Database.BatchableContext context) {
    if (!GeotabApiService.isIntegrationActive()) {
      return new List<Object>();
    }
    Geotab_Integration_Config__mdt config = GeotabApiService.getActiveConfig();
    if (config == null || config.Device_Sync_Enabled__c != true) {
      return new List<Object>();
    }

    Geotab_Sync_State__c state = GeotabApiService.getSyncState();
    feedVersion = String.isBlank(state.Device_Feed_Version__c) ? '0' : state.Device_Feed_Version__c;
    GeotabApiService.FeedResult feed = GeotabApiService.getFeed('Device', feedVersion);
    feedVersion = feed.toVersion;
    return feed.data == null ? new List<Object>() : feed.data;
  }

  public void execute(Database.BatchableContext context, List<Object> scope) {
    if (scope == null || scope.isEmpty()) {
      return;
    }

    List<fax__Vehicle__c> vehicles = new List<fax__Vehicle__c>();
    DateTime now = System.now();
    for (Object row : scope) {
      fax__Vehicle__c vehicle = mapDeviceToVehicle((Map<String, Object>) row, now);
      if (vehicle != null) {
        vehicles.add(vehicle);
      }
    }
    if (vehicles.isEmpty()) {
      return;
    }
    Database.UpsertResult[] results = Database.upsert(vehicles, fax__Vehicle__c.Geotab_Device_Id__c, false);
    for (Database.UpsertResult result : results) {
      if (result.isSuccess()) {
        processedCount++;
      }
    }
  }

  public void finish(Database.BatchableContext context) {
    Geotab_Sync_State__c state = GeotabApiService.getSyncState();
    state.Device_Feed_Version__c = feedVersion;
    GeotabApiService.upsertSyncState(state);
    GeotabApiService.updateSyncStatus('DeviceSyncComplete', 'Devices processed: ' + processedCount);
  }

  @TestVisible
  private static fax__Vehicle__c mapDeviceToVehicle(Map<String, Object> device, DateTime syncTime) {
    if (device == null || String.isBlank((String) device.get('id'))) {
      return null;
    }
    fax__Vehicle__c vehicle = new fax__Vehicle__c();
    vehicle.Geotab_Device_Id__c = (String) device.get('id');
    vehicle.Geotab_Serial_Number__c = (String) device.get('serialNumber');
    vehicle.Geotab_VIN__c = (String) device.get('vehicleIdentificationNumber');
    vehicle.Geotab_Last_Sync__c = syncTime;

    String deviceName = (String) device.get('name');
    if (String.isNotBlank(deviceName)) {
      vehicle.Name = deviceName.left(80);
    } else if (String.isNotBlank(vehicle.Geotab_Serial_Number__c)) {
      vehicle.Name = vehicle.Geotab_Serial_Number__c.left(80);
    } else {
      vehicle.Name = 'Geotab Device ' + vehicle.Geotab_Device_Id__c.left(60);
    }

    String licensePlate = (String) device.get('licensePlate');
    if (String.isNotBlank(licensePlate)) {
      vehicle.fax__Brief_Details__c = 'Plate: ' + licensePlate;
    }
    return vehicle;
  }
}