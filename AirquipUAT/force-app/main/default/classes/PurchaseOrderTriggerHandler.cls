public with sharing class PurchaseOrderTriggerHandler {

    private static final String MAPPING_OBJECT = 'faxa__Purchase_Order__c';

    private static Set<String> getSyncFields() {
        return new MappingFieldLoader().loadSyncFields();
    }

    public static void handleBeforeInsert(List<faxa__Purchase_Order__c> newList) {
        for (faxa__Purchase_Order__c po : newList) {
            po.faxa__Sync_to_QuickBooks__c = true;
        }
    }

    public static void handleBeforeUpdate(
        List<faxa__Purchase_Order__c> newList,
        Map<Id, faxa__Purchase_Order__c> oldMap
    ) {
        applySyncFlag(newList, oldMap);
    }

    private static void applySyncFlag(
        List<faxa__Purchase_Order__c> newList,
        Map<Id, faxa__Purchase_Order__c> oldMap
    ) {
        Set<String> syncFields = getSyncFields();
        if (syncFields.isEmpty()) {
            return;
        }

        for (faxa__Purchase_Order__c po : newList) {
            faxa__Purchase_Order__c oldPo = oldMap.get(po.Id);

            if (wasSyncFieldExplicitlyChanged(po, oldPo)) {
                continue;
            }

            if (!isSyncFieldChanged(po, oldPo, syncFields)) {
                continue;
            }

            po.faxa__Sync_to_QuickBooks__c = true;
        }
    }

    private static Boolean wasSyncFieldExplicitlyChanged(
        faxa__Purchase_Order__c newPo,
        faxa__Purchase_Order__c oldPo
    ) {
        if (newPo.faxa__Sync_to_QuickBooks__c == null) {
            return false;
        }
        return newPo.faxa__Sync_to_QuickBooks__c != oldPo.faxa__Sync_to_QuickBooks__c;
    }

    private static Boolean isSyncFieldChanged(
        faxa__Purchase_Order__c newPo,
        faxa__Purchase_Order__c oldPo,
        Set<String> syncFields
    ) {
        for (String fieldName : syncFields) {
            Object newValue = newPo.get(fieldName);
            Object oldValue = oldPo.get(fieldName);

            if (newValue == null && oldValue != null) {
                continue;
            }

            if (newValue != oldValue) {
                return true;
            }
        }
        return false;
    }

    private without sharing class MappingFieldLoader {
        public Set<String> loadSyncFields() {
            Set<String> fields = new Set<String>();
            for (faxa__Mapping__c mapping : [
                SELECT faxa__FieldAx_Field__c
                FROM faxa__Mapping__c
                WHERE faxa__FieldAx_Object__c = :MAPPING_OBJECT
                AND faxa__FieldAx_Field__c != null
                AND faxa__External_App__r.Name = 'QuickBook'
            ]) {
                fields.add(mapping.faxa__FieldAx_Field__c);
            }
            return fields;
        }
    }
}