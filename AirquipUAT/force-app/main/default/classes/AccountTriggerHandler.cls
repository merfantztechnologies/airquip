public class AccountTriggerHandler {

    private static Set<String> getSyncFields() {
        Set<String> fields = new Set<String>();

        try {
            for (faxa__Mapping__c mapping : [
                SELECT faxa__FieldAx_Field__c
                FROM faxa__Mapping__c
                WHERE faxa__FieldAx_Object__c = 'Account'
                AND faxa__FieldAx_Field__c != null
                AND faxa__External_App__r.Name = 'QuickBook'
            ]) {
                fields.add(mapping.faxa__FieldAx_Field__c);
            }
        } catch (Exception e) {
            System.debug('Error while fetching sync fields: ' + e.getMessage());
        }

        return fields;
    }

    public static void handleAfterInsert(List<Account> newList) {

        List<Account> accountsToUpdate = new List<Account>();

        for (Account acc : newList) {
            accountsToUpdate.add(new Account(
                Id = acc.Id,
                faxa__Sync_to_QuickBooks__c = true
            ));
        }

        if (!accountsToUpdate.isEmpty()) {
            try {
                update accountsToUpdate;
            } catch (DmlException e) {
                System.debug('Error updating Accounts after insert: ' + e.getMessage());
            }
        }
    }

    public static void handleAfterUpdate(List<Account> newList, Map<Id, Account> oldMap) {

        Set<String> syncFields = getSyncFields();

        if (syncFields.isEmpty()) {
            return;
        }

        List<Account> accountsToUpdate = new List<Account>();

        for (Account acc : newList) {

            Account oldAcc = oldMap.get(acc.Id);

            if (acc.faxa__Sync_to_QuickBooks__c != oldAcc.faxa__Sync_to_QuickBooks__c) {
                continue;
            }

            if (isSyncFieldChanged(acc, oldAcc, syncFields)) {
                accountsToUpdate.add(new Account(
                    Id = acc.Id,
                    faxa__Sync_to_QuickBooks__c = true
                ));
            }
        }

        if (!accountsToUpdate.isEmpty()) {
            try {
                update accountsToUpdate;
            } catch (DmlException e) {
                System.debug('Error updating Accounts after update: ' + e.getMessage());
            }
        }
    }

    private static Boolean isSyncFieldChanged(Account newAcc, Account oldAcc, Set<String> syncFields) {

        for (String fieldName : syncFields) {
            if (newAcc.get(fieldName) != oldAcc.get(fieldName)) {
                return true;
            }
        }

        return false;
    }
}