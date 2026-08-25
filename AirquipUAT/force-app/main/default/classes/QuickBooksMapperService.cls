public class QuickBooksMapperService {

    public class QuickBooksMapperException extends Exception {}

    /**
     * ENTRY POINT
     */
    public static String buildPayload(
        String objectName,
        Id recordId,
        Id externalAppId,
        String operation
    ) {

        System.debug('=== buildPayload START ===');
        System.debug('Object: ' + objectName);
        System.debug('RecordId: ' + recordId);
        System.debug('Operation: ' + operation);

        List<faxa__Mapping__c> parentMappings =
            getMappingsForObject(objectName, externalAppId);

        System.debug('Mappings fetched: ' + parentMappings.size());
        System.debug('Mappings: ' + parentMappings);

        if (parentMappings.isEmpty()) {
            throw new QuickBooksMapperException(
                'No mappings found for object: ' + objectName
            );
        }

        // Get record data
        SObject record = getRecordData(objectName, recordId, parentMappings);

        System.debug('Record fetched: ' + record);

        Map<String, Object> payload = new Map<String, Object>();

        // Include QB Id for update
        if ('UPDATE'.equalsIgnoreCase(operation)) {
            String qbId = getQuickBooksIdFromRecord(objectName, record);
            System.debug('QB Id found: ' + qbId);

            if (String.isNotBlank(qbId)) {
                payload.put('Id', qbId);
            }
        }

        // Map fields
        for (faxa__Mapping__c mapping : parentMappings) {
            try {
                System.debug('--- Processing Mapping ---');
                System.debug('Source Field: ' + mapping.faxa__FieldAx_Field__c);
                System.debug('Target Field: ' + mapping.faxa__External_App_Field__c);

                Object value = transformValue(mapping, record);

                System.debug('Transformed Value: ' + value);

                if (value != null) {
                    setNestedValue(payload, mapping.faxa__External_App_Field__c, value);
                }

            } catch (Exception e) {
                System.debug('❌ Mapping error: ' + e.getMessage());
            }
        }

        String finalPayload = JSON.serializePretty(payload);

        System.debug('Final Payload: ' + finalPayload);
        System.debug('=== buildPayload END ===');

        return finalPayload;
    }

    // ===========================
    // 🔧 GET RECORD DATA
    // ===========================
    private static SObject getRecordData(
        String objectName,
        Id recordId,
        List<faxa__Mapping__c> mappings
    ) {

        Set<String> fields = new Set<String>{ 'Id' };

        for (faxa__Mapping__c m : mappings) {
            if (String.isNotBlank(m.faxa__FieldAx_Field__c)) {
                fields.add(m.faxa__FieldAx_Field__c);
            }
        }

        String soql =
            'SELECT ' + String.join(new List<String>(fields), ',') +
            ' FROM ' + objectName +
            ' WHERE Id = :recordId';

        System.debug('SOQL Query: ' + soql);

        return Database.query(soql);
    }

    // ===========================
    // 🔧 FIELD TRANSFORM
    // ===========================
    private static Object transformValue(
        faxa__Mapping__c mapping,
        SObject record
    ) {

        if (String.isBlank(mapping.faxa__FieldAx_Field__c)) {
            System.debug('Using default value (no source field): ' + mapping.faxa__Default_Value__c);
            return mapping.faxa__Default_Value__c;
        }

        Object val = record.get(mapping.faxa__FieldAx_Field__c);

        System.debug('Raw value from record: ' + val);

        if (val == null) {
            System.debug('Value is null, using default: ' + mapping.faxa__Default_Value__c);
            return mapping.faxa__Default_Value__c;
        }

        return val;
    }

    // ===========================
    // 🔧 SET NESTED JSON
    // ===========================
    private static void setNestedValue(
        Map<String, Object> root,
        String path,
        Object value
    ) {
        if (String.isBlank(path)) return;

        System.debug('Setting nested value. Path: ' + path + ' | Value: ' + value);

        List<String> parts = path.split('\\.');
        Map<String, Object> current = root;

        for (Integer i = 0; i < parts.size(); i++) {
            String key = parts[i];

            if (i == parts.size() - 1) {
                current.put(key, value);
            } else {
                if (!current.containsKey(key)) {
                    current.put(key, new Map<String, Object>());
                }
                current = (Map<String, Object>) current.get(key);
            }
        }
    }

    // ===========================
    // 🔧 GET QB ID FIELD
    // ===========================
    private static String getQuickBooksIdFromRecord(
        String objectName,
        SObject record
    ) {

        Map<String, Schema.SObjectField> fields =
            record.getSObjectType().getDescribe().fields.getMap();

        System.debug('Available fields: ' + fields.keySet());

        List<String> candidates = new List<String>{
            'faxa__QuickBooks_Customer_Id__c',
            'QuickBooks_Customer_Id__c',
            'QB_Customer_Id__c'
        };

        for (String f : candidates) {
            if (fields.containsKey(f)) { // ✅ FIXED (removed toLowerCase)
                Object val = record.get(f);
                System.debug('Checking field: ' + f + ' | Value: ' + val);

                if (val != null) return String.valueOf(val);
            }
        }

        return null;
    }

    // ===========================
    // 🔧 GET MAPPINGS
    // ===========================
    private static List<faxa__Mapping__c> getMappingsForObject(
        String objectName,
        Id externalAppId
    ) {

        List<faxa__Mapping__c> mappings = [
            SELECT Id,
                   Name,
                   faxa__FieldAx_Object__c,
                   faxa__FieldAx_Field__c,
                   faxa__External_Object__c,
                   faxa__External_App_Field__c,
                   faxa__Is_Required__c,
                   faxa__Default_Value__c,
                   faxa__Sequence__c
            FROM faxa__Mapping__c
            WHERE faxa__FieldAx_Object__c = :objectName
            AND faxa__External_App__c = :externalAppId
            ORDER BY faxa__Sequence__c
        ];

        System.debug('Mappings Query Result: ' + mappings);

        return mappings;
    }

    // ===========================
    // 🔧 PUBLIC HELPER
    // ===========================
    public static List<faxa__Mapping__c> getParentMappingsForFieldAxObject(
        String objectName,
        Id externalAppId
    ) {
        return getMappingsForObject(objectName, externalAppId);
    }
}