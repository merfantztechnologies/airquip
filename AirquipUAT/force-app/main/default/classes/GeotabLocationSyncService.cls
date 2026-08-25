/**
 * Syncs Geotab device status to FieldAX Service Engineers via Vehicle / Vehicle Mapped records.
 */
public with sharing class GeotabLocationSyncService {

  private static final String DEVICE_STATUS_FEED = 'DeviceStatusInfo';
  private static Boolean technicianLocationHasLocationField;

  public class SyncSummary {
    public Integer statusRecordsProcessed = 0;
    public Integer engineersUpdated = 0;
    public Integer historyRecordsCreated = 0;
  }

  public static SyncSummary syncLatestLocations() {
    Geotab_Integration_Config__mdt config = GeotabApiService.getActiveConfig();
    if (config == null) {
      return new SyncSummary();
    }

    Geotab_Sync_State__c state = GeotabApiService.getSyncState();
    String fromVersion = String.isBlank(state.DeviceStatusInfo_Feed_Version__c)
      ? '0'
      : state.DeviceStatusInfo_Feed_Version__c;

    GeotabApiService.FeedResult feed = GeotabApiService.getFeed(DEVICE_STATUS_FEED, fromVersion);
    System.debug('FROM VERSION = ' + fromVersion);
    SyncSummary summary = processDeviceStatusFeed(feed.data, config);

    state.DeviceStatusInfo_Feed_Version__c = feed.toVersion;
    System.debug('TO VERSION = ' + feed.toVersion);
    GeotabApiService.upsertSyncState(state);
    GeotabApiService.updateSyncStatus('Success', null);
    return summary;
  }

  @TestVisible
  private static SyncSummary processDeviceStatusFeed(
    List<Object> feedData,
    Geotab_Integration_Config__mdt config
  ) {
    SyncSummary summary = new SyncSummary();
    if (feedData == null || feedData.isEmpty()) {
      return summary;
    }

    Map<String, DeviceStatusPayload> latestByDeviceId = new Map<String, DeviceStatusPayload>();
    for (Object row : feedData) {
      DeviceStatusPayload payload = parseDeviceStatus((Map<String, Object>) row);
      if (payload == null || String.isBlank(payload.deviceId)) {
        continue;
      }
      summary.statusRecordsProcessed++;
      latestByDeviceId.put(payload.deviceId, payload);
    }

    if (latestByDeviceId.isEmpty()) {
      return summary;
    }

    Map<String, List<EngineerMapping>> mappingsByDeviceId = loadActiveMappings(latestByDeviceId.keySet());
    if (mappingsByDeviceId.isEmpty()) {
      return summary;
    }

    Map<Id, EngineerUpdate> engineerUpdates = new Map<Id, EngineerUpdate>();
    List<fax__Technician_Location__c> historyRows = new List<fax__Technician_Location__c>();
    Integer historyIntervalMinutes = config.Location_History_Interval_Minutes__c != null
      ? Integer.valueOf(config.Location_History_Interval_Minutes__c.intValue())
      : 5;

    Map<Id, DateTime> lastHistoryByEngineer = config.Create_Location_History__c
      ? loadRecentHistoryTimes(engineerIdsFromMappings(mappingsByDeviceId), historyIntervalMinutes)
      : new Map<Id, DateTime>();

    for (String deviceId : latestByDeviceId.keySet()) {
      if (!mappingsByDeviceId.containsKey(deviceId)) {
        continue;
      }
      DeviceStatusPayload payload = latestByDeviceId.get(deviceId);
      for (EngineerMapping mapping : mappingsByDeviceId.get(deviceId)) {
        if (!isTrackableEngineer(mapping)) {
          continue;
        }

        EngineerUpdate updateRow = engineerUpdates.containsKey(mapping.engineerId)
          ? engineerUpdates.get(mapping.engineerId)
          : new EngineerUpdate(mapping.engineerId);
        updateRow.latitude = payload.latitude;
        updateRow.longitude = payload.longitude;
        updateRow.gpsTime = payload.gpsTime;
        engineerUpdates.put(mapping.engineerId, updateRow);

        if (config.Create_Location_History__c && shouldCreateHistory(mapping.engineerId, payload.gpsTime, lastHistoryByEngineer, historyIntervalMinutes)) {
          historyRows.add(buildTechnicianLocation(mapping.engineerId, payload));
          lastHistoryByEngineer.put(mapping.engineerId, payload.gpsTime);
        }
      }
    }

    summary.engineersUpdated = persistEngineerUpdates(engineerUpdates.values());
    if (!historyRows.isEmpty()) {
      insert historyRows;
      summary.historyRecordsCreated = historyRows.size();
    }
    return summary;
  }

  private static Set<Id> engineerIdsFromMappings(Map<String, List<EngineerMapping>> mappingsByDeviceId) {
    Set<Id> engineerIds = new Set<Id>();
    for (List<EngineerMapping> rows : mappingsByDeviceId.values()) {
      for (EngineerMapping row : rows) {
        engineerIds.add(row.engineerId);
      }
    }
    return engineerIds;
  }

  private static Boolean isTrackableEngineer(EngineerMapping mapping) {
    return mapping.engineerId != null
      && mapping.enableGpsTracking == true
      && mapping.activeStatus == 'Yes';
  }

  private static Boolean shouldCreateHistory(
    Id engineerId,
    DateTime gpsTime,
    Map<Id, DateTime> lastHistoryByEngineer,
    Integer historyIntervalMinutes
  ) {
    if (gpsTime == null) {
      return false;
    }
    if (!lastHistoryByEngineer.containsKey(engineerId)) {
      return true;
    }
    Long elapsedMs = gpsTime.getTime() - lastHistoryByEngineer.get(engineerId).getTime();
    return elapsedMs >= (historyIntervalMinutes * 60 * 1000);
  }

  private static Map<Id, DateTime> loadRecentHistoryTimes(Set<Id> engineerIds, Integer historyIntervalMinutes) {
    Map<Id, DateTime> result = new Map<Id, DateTime>();
    if (engineerIds.isEmpty()) {
      return result;
    }
    DateTime threshold = System.now().addMinutes(-historyIntervalMinutes);
    for (AggregateResult ar : [
      SELECT fax__Service_Engineer__c engineerId, MAX(fax__GPS_Time__c) lastGps
      FROM fax__Technician_Location__c
      WHERE fax__Service_Engineer__c IN :engineerIds
        AND fax__GPS_Time__c >= :threshold
      GROUP BY fax__Service_Engineer__c
    ]) {
      result.put((Id) ar.get('engineerId'), (DateTime) ar.get('lastGps'));
    }
    return result;
  }

  private static Map<String, List<EngineerMapping>> loadActiveMappings(Set<String> deviceIds) {
    Map<String, List<EngineerMapping>> result = new Map<String, List<EngineerMapping>>();
    for (fax__Vehicle_Mapped__c row : [
      SELECT
        Id,
        fax__Vehicle__c,
        fax__Vehicle__r.Geotab_Device_Id__c,
        fax__Service_Engineer__c,
        fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c,
        fax__Service_Engineer__r.fax__Active__c,
        fax__Status__c,
        fax__Start__c,
        fax__End__c
      FROM fax__Vehicle_Mapped__c
      WHERE fax__Vehicle__r.Geotab_Device_Id__c IN :deviceIds
        AND fax__Service_Engineer__c != NULL
        AND (fax__End__c = NULL OR fax__End__c >= TODAY)
        AND (fax__Start__c = NULL OR fax__Start__c <= TODAY)
    ]) {
      if (String.isBlank(row.fax__Vehicle__r.Geotab_Device_Id__c)) {
        continue;
      }
      if (String.isNotBlank(row.fax__Status__c) && row.fax__Status__c != 'Active') {
        continue;
      }
      EngineerMapping mapping = new EngineerMapping();
      mapping.engineerId = row.fax__Service_Engineer__c;
      mapping.enableGpsTracking = row.fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c;
      mapping.activeStatus = row.fax__Service_Engineer__r.fax__Active__c;

      String deviceId = row.fax__Vehicle__r.Geotab_Device_Id__c;
      if (!result.containsKey(deviceId)) {
        result.put(deviceId, new List<EngineerMapping>());
      }
      result.get(deviceId).add(mapping);
    }
    return result;
  }

  private static Integer persistEngineerUpdates(List<EngineerUpdate> updates) {
    if (updates.isEmpty()) {
      return 0;
    }
    List<fax__Service_Engineer__c> rows = new List<fax__Service_Engineer__c>();
    for (EngineerUpdate updateRow : updates) {
      rows.add(new fax__Service_Engineer__c(
        Id = updateRow.engineerId,
        fax__Latitude__c = updateRow.latitude,
        fax__Longitude__c = updateRow.longitude
      ));
    }
    Database.SaveResult[] results = Database.update(rows, false);
    Integer successCount = 0;
    List<String> errors = new List<String>();
    for (Integer index = 0; index < results.size(); index++) {
      if (results[index].isSuccess()) {
        successCount++;
        continue;
      }
      errors.add(rows[index].Id + ': ' + results[index].getErrors()[0].getMessage());
    }
    if (!errors.isEmpty()) {
      throw new GeotabApiService.GeotabApiException(
        'Failed to update Geotab engineer locations: ' + String.join(errors, '; ')
      );
    }
    return successCount;
  }

  private static fax__Technician_Location__c buildTechnicianLocation(Id engineerId, DeviceStatusPayload payload) {
    fax__Technician_Location__c row = new fax__Technician_Location__c(
      fax__Service_Engineer__c = engineerId,
      fax__GPS_Time__c = payload.gpsTime
    );
    setGeolocation(row, payload.latitude, payload.longitude);
    return row;
  }

  private static void setGeolocation(SObject row, String latitude, String longitude) {
    if (String.isBlank(latitude) || String.isBlank(longitude)) {
      return;
    }
    if (!technicianLocationSupportsLocationField(row)) {
      return;
    }
    row.put('fax__Location__Latitude__s', Decimal.valueOf(latitude));
    row.put('fax__Location__Longitude__s', Decimal.valueOf(longitude));
  }

  private static Boolean technicianLocationSupportsLocationField(SObject row) {
    if (technicianLocationHasLocationField == null) {
      Map<String, Schema.SObjectField> fieldMap = row.getSObjectType().getDescribe().fields.getMap();
      technicianLocationHasLocationField = fieldMap.containsKey('fax__Location__c')
        && fieldMap.get('fax__Location__c').getDescribe().getType() == Schema.DisplayType.LOCATION;
    }
    return technicianLocationHasLocationField;
  }

  @TestVisible
  private static DeviceStatusPayload parseDeviceStatus(Map<String, Object> row) {
    if (row == null) {
      return null;
    }
    DeviceStatusPayload payload = new DeviceStatusPayload();
    Map<String, Object> device = (Map<String, Object>) row.get('device');
    payload.deviceId = device != null ? (String) device.get('id') : null;
    payload.latitude = stringifyCoordinate(row.get('latitude'));
    payload.longitude = stringifyCoordinate(row.get('longitude'));
    payload.gpsTime = parseGeotabDateTime(row.get('dateTime'));
    return payload;
  }

  private static String stringifyCoordinate(Object value) {
    if (value == null) {
      return null;
    }
    return String.valueOf(value);
  }

  private static DateTime parseGeotabDateTime(Object value) {
    if (value == null) {
      return null;
    }
    String raw = String.valueOf(value);
    if (raw.endsWith('Z')) {
      raw = raw.replace('Z', '');
    }
    return (DateTime) JSON.deserialize('"' + raw + '"', DateTime.class);
  }

  @TestVisible
  public class DeviceStatusPayload {
    public String deviceId;
    public String latitude;
    public String longitude;
    public DateTime gpsTime;
  }

  private class EngineerMapping {
    public Id engineerId;
    public Boolean enableGpsTracking;
    public String activeStatus;
  }

  private class EngineerUpdate {
    public Id engineerId;
    public String latitude;
    public String longitude;
    public DateTime gpsTime;

    public EngineerUpdate(Id engineerId) {
      this.engineerId = engineerId;
    }
  }
}