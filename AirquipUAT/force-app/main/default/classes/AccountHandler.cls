public class AccountHandler {
    
    public static void preventDuplicateQBVendors(List<Account> newAccounts, Map<Id, Account> oldAccountMap) {
        Set<String> qbVendorIdsToCheck = new Set<String>();
        Set<String> duplicateIds = new Set<String>();

        // Step 1: Collect non-blank QB Vendor IDs from the incoming records
        for (Account acc : newAccounts) {
            if (String.isNotBlank(acc.faxa__QuickBooks_Vendor_Id__c)) {
                
                // UPDATE PROTECTION: Only check if the QB ID was just added or changed.
                // If the ID is identical to what it was before the update, skip it.
                if (oldAccountMap != null && oldAccountMap.containsKey(acc.Id)) {
                    Account oldAcc = oldAccountMap.get(acc.Id);
                    if (acc.faxa__QuickBooks_Vendor_Id__c == oldAcc.faxa__QuickBooks_Vendor_Id__c) {
                        continue; 
                    }
                }

                // Check if the same ID is being processed twice in this exact batch
                if (qbVendorIdsToCheck.contains(acc.faxa__QuickBooks_Vendor_Id__c)) {
                    duplicateIds.add(acc.faxa__QuickBooks_Vendor_Id__c);
                    acc.addError('Duplicate QuickBooks Vendor ID found within this batch: ' + acc.faxa__QuickBooks_Vendor_Id__c);
                } else {
                    qbVendorIdsToCheck.add(acc.faxa__QuickBooks_Vendor_Id__c);
                }
            }
        }

        // Step 2: Query the database to see if these NEW/CHANGED IDs already exist
        if (!qbVendorIdsToCheck.isEmpty()) {
            for (Account existingAcc : [
                SELECT faxa__QuickBooks_Vendor_Id__c 
                FROM Account 
                WHERE faxa__QuickBooks_Vendor_Id__c IN :qbVendorIdsToCheck
            ]) {
                duplicateIds.add(existingAcc.faxa__QuickBooks_Vendor_Id__c);
            }
        }

        // Step 3: Flag any incoming records that match the found duplicates
        if (!duplicateIds.isEmpty()) {
            for (Account acc : newAccounts) {
                if (String.isNotBlank(acc.faxa__QuickBooks_Vendor_Id__c)) {
                    
                    // Re-verify that this record's ID was actually changed before flagging it
                    Boolean isIdChanged = (oldAccountMap == null || !oldAccountMap.containsKey(acc.Id) || acc.faxa__QuickBooks_Vendor_Id__c != oldAccountMap.get(acc.Id).faxa__QuickBooks_Vendor_Id__c);
                    
                    if (isIdChanged && duplicateIds.contains(acc.faxa__QuickBooks_Vendor_Id__c)) {
                        if (!acc.hasErrors()) {
                            acc.faxa__QuickBooks_Vendor_Id__c.addError('An Account with this QuickBooks Vendor ID (' + acc.faxa__QuickBooks_Vendor_Id__c + ') already exists.');
                        }
                    }
                }
            }
        }
    }
}