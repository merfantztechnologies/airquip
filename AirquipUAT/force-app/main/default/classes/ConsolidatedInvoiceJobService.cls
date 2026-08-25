public without sharing class ConsolidatedInvoiceJobService {
    public static final Set<String> ALLOWED_EXISTING_INVOICE_STATUSES = new Set<String>{
        'Draft',
        'In Review',
        'Approved'
    };

    public static Boolean isBlockingInvoiceStatus(String invoiceStatus) {
        return String.isNotBlank(invoiceStatus) && !ALLOWED_EXISTING_INVOICE_STATUSES.contains(invoiceStatus);
    }

    public static void preventDoubleBilling(List<Consolidated_Invoice_Job__c> newRecords) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Set<Id> jobIds = new Set<Id>();
        Set<String> duplicateKeysInBatch = new Set<String>();

        for (Consolidated_Invoice_Job__c junctionRecord : newRecords) {
            if (junctionRecord.Job__c == null || junctionRecord.Invoice__c == null) {
                continue;
            }

            jobIds.add(junctionRecord.Job__c);
            String junctionKey = buildJunctionKey(junctionRecord.Invoice__c, junctionRecord.Job__c);
            if (duplicateKeysInBatch.contains(junctionKey)) {
                junctionRecord.addError('This Job is already being added to this Invoice.');
                continue;
            }
            duplicateKeysInBatch.add(junctionKey);
        }

        if (jobIds.isEmpty()) {
            return;
        }

        for (Consolidated_Invoice_Job__c existingRecord : [
            SELECT Invoice__c, Job__c, Invoice__r.fax__Status__c
            FROM Consolidated_Invoice_Job__c
            WHERE Job__c IN :jobIds
        ]) {
            for (Consolidated_Invoice_Job__c junctionRecord : newRecords) {
                if (junctionRecord.Job__c != existingRecord.Job__c) {
                    continue;
                }

                if (junctionRecord.Invoice__c == existingRecord.Invoice__c) {
                    junctionRecord.addError('This Job is already linked to this Invoice.');
                    continue;
                }

                if (isBlockingInvoiceStatus(existingRecord.Invoice__r.fax__Status__c)) {
                    junctionRecord.addError(
                        'This Job is already linked to an ineligible invoice and cannot be billed again.'
                    );
                }
            }
        }

        for (fax__Invoice__c invoiceRecord : [
            SELECT Id, fax__Job__c, fax__Status__c
            FROM fax__Invoice__c
            WHERE fax__Job__c IN :jobIds
        ]) {
            if (!isBlockingInvoiceStatus(invoiceRecord.fax__Status__c)) {
                continue;
            }

            for (Consolidated_Invoice_Job__c junctionRecord : newRecords) {
                if (
                    junctionRecord.Job__c == invoiceRecord.fax__Job__c &&
                    junctionRecord.Invoice__c != invoiceRecord.Id
                ) {
                    junctionRecord.addError(
                        'This Job is already linked to an ineligible invoice and cannot be billed again.'
                    );
                }
            }
        }
    }

    public static void deleteIndividualJobInvoices(List<Consolidated_Invoice_Job__c> junctionRecords) {
        if (junctionRecords == null || junctionRecords.isEmpty()) {
            return;
        }

        Set<Id> consolidatedInvoiceIds = new Set<Id>();
        Set<Id> jobIds = new Set<Id>();

        for (Consolidated_Invoice_Job__c junctionRecord : junctionRecords) {
            if (junctionRecord.Invoice__c != null) {
                consolidatedInvoiceIds.add(junctionRecord.Invoice__c);
            }
            if (junctionRecord.Job__c != null) {
                jobIds.add(junctionRecord.Job__c);
            }
        }

        if (jobIds.isEmpty() || consolidatedInvoiceIds.isEmpty()) {
            return;
        }

        List<fax__Invoice__c> individualInvoices = new List<fax__Invoice__c>();
        for (fax__Invoice__c invoiceRecord : [
            SELECT Id, fax__Job__c, fax__Status__c
            FROM fax__Invoice__c
            WHERE fax__Job__c IN :jobIds
            AND Id NOT IN :consolidatedInvoiceIds
        ]) {
            if (!isBlockingInvoiceStatus(invoiceRecord.fax__Status__c)) {
                individualInvoices.add(invoiceRecord);
            }
        }

        if (individualInvoices.isEmpty()) {
            return;
        }

        Set<Id> jobIdsToUpdate = new Set<Id>();
        for (fax__Invoice__c invoiceRecord : individualInvoices) {
            if (invoiceRecord.fax__Job__c != null) {
                jobIdsToUpdate.add(invoiceRecord.fax__Job__c);
            }
        }

        if (!jobIdsToUpdate.isEmpty()) {
            List<fax__Job__c> jobsToClearInvoiceRequired = new List<fax__Job__c>();
            for (Id jobId : jobIdsToUpdate) {
                jobsToClearInvoiceRequired.add(
                    new fax__Job__c(Id = jobId, Invoice_Required__c = false)
                );
            }
            Database.update(jobsToClearInvoiceRequired, AccessLevel.SYSTEM_MODE);
        }

        Database.delete(individualInvoices, AccessLevel.SYSTEM_MODE);

        if (!jobIdsToUpdate.isEmpty()) {
            List<fax__Job__c> jobsToRestoreInvoiceRequired = new List<fax__Job__c>();
            for (Id jobId : jobIdsToUpdate) {
                jobsToRestoreInvoiceRequired.add(
                    new fax__Job__c(Id = jobId, Invoice_Required__c = true)
                );
            }
            Database.update(jobsToRestoreInvoiceRequired, AccessLevel.SYSTEM_MODE);
        }
    }

    public static void createInvoiceLineItems(List<Consolidated_Invoice_Job__c> junctionRecords) {
        if (junctionRecords == null || junctionRecords.isEmpty()) {
            return;
        }

        Set<Id> invoiceIds = new Set<Id>();
        Set<Id> jobIds = new Set<Id>();

        for (Consolidated_Invoice_Job__c junctionRecord : junctionRecords) {
            if (junctionRecord.Invoice__c != null && junctionRecord.Job__c != null) {
                invoiceIds.add(junctionRecord.Invoice__c);
                jobIds.add(junctionRecord.Job__c);
            }
        }

        if (invoiceIds.isEmpty() || jobIds.isEmpty()) {
            return;
        }

        Map<Id, fax__Invoice__c> invoicesById = new Map<Id, fax__Invoice__c>([
            SELECT Id, fax__Job__c
            FROM fax__Invoice__c
            WHERE Id IN :invoiceIds
        ]);

        Map<Id, Set<Id>> jobIdsByInvoiceId = new Map<Id, Set<Id>>();
        for (Consolidated_Invoice_Job__c junctionRecord : junctionRecords) {
            fax__Invoice__c invoiceRecord = invoicesById.get(junctionRecord.Invoice__c);
            if (invoiceRecord == null || junctionRecord.Job__c == null) {
                continue;
            }

            if (junctionRecord.Job__c == invoiceRecord.fax__Job__c) {
                continue;
            }

            Set<Id> invoiceJobIds = jobIdsByInvoiceId.get(junctionRecord.Invoice__c);
            if (invoiceJobIds == null) {
                invoiceJobIds = new Set<Id>();
                jobIdsByInvoiceId.put(junctionRecord.Invoice__c, invoiceJobIds);
            }
            invoiceJobIds.add(junctionRecord.Job__c);
        }

        if (jobIdsByInvoiceId.isEmpty()) {
            return;
        }

        Set<Id> jobsToCopy = new Set<Id>();
        for (Set<Id> invoiceJobIds : jobIdsByInvoiceId.values()) {
            jobsToCopy.addAll(invoiceJobIds);
        }

        List<fax__Invoice_Line_Item__c> lineItemsToInsert = new List<fax__Invoice_Line_Item__c>();

        for (fax__Job_System__c jobItem : [
            SELECT Id,
                   fax__Job_New__c,
                   fax__Product__c,
                   fax__Product__r.Description,
                   fax__Quantity__c,
                   fax__Unit_Price__c,
                   fax__Discount__c
            FROM fax__Job_System__c
            WHERE fax__Job_New__c IN :jobsToCopy
            AND fax__Product__c != NULL
            AND fax__Billable__c = TRUE
            ORDER BY CreatedDate ASC
        ]) {
            Id invoiceId = findInvoiceForJob(jobIdsByInvoiceId, jobItem.fax__Job_New__c);
            if (invoiceId == null) {
                continue;
            }

            lineItemsToInsert.add(
                buildLineItemFromJobSystem(invoiceId, jobItem)
            );
        }

        if (!lineItemsToInsert.isEmpty()) {
            Database.insert(lineItemsToInsert, AccessLevel.SYSTEM_MODE);
        }
    }

    public static void deleteInvoiceLineItems(List<Consolidated_Invoice_Job__c> junctionRecords) {
        if (junctionRecords == null || junctionRecords.isEmpty()) {
            return;
        }

        Set<Id> invoiceIds = new Set<Id>();
        Set<Id> jobIds = new Set<Id>();

        for (Consolidated_Invoice_Job__c junctionRecord : junctionRecords) {
            if (junctionRecord.Invoice__c != null && junctionRecord.Job__c != null) {
                invoiceIds.add(junctionRecord.Invoice__c);
                jobIds.add(junctionRecord.Job__c);
            }
        }

        if (invoiceIds.isEmpty() || jobIds.isEmpty()) {
            return;
        }

        List<fax__Invoice_Line_Item__c> lineItemsToDelete = new List<fax__Invoice_Line_Item__c>();
        for (fax__Invoice_Line_Item__c lineItem : (List<fax__Invoice_Line_Item__c>) Database.queryWithBinds(
            'SELECT Id, Job_Item_Lookup__c, Consolidated_Job__c, ' +
            'Job_Item_Lookup__r.fax__Job_New__c ' +
            'FROM fax__Invoice_Line_Item__c ' +
            'WHERE fax__Invoice__c IN :invoiceIds',
            new Map<String, Object>{ 'invoiceIds' => invoiceIds },
            AccessLevel.SYSTEM_MODE
        )) {
            if (
                jobIds.contains(lineItem.Consolidated_Job__c) ||
                jobIds.contains(lineItem.Job_Item_Lookup__r.fax__Job_New__c)
            ) {
                lineItemsToDelete.add(lineItem);
            }
        }

        if (!lineItemsToDelete.isEmpty()) {
            Database.delete(lineItemsToDelete, AccessLevel.SYSTEM_MODE);
        }
    }

    private static Id findInvoiceForJob(Map<Id, Set<Id>> jobIdsByInvoiceId, Id jobId) {
        for (Id invoiceId : jobIdsByInvoiceId.keySet()) {
            if (jobIdsByInvoiceId.get(invoiceId).contains(jobId)) {
                return invoiceId;
            }
        }
        return null;
    }

    private static fax__Invoice_Line_Item__c buildLineItemFromJobSystem(
        Id invoiceId,
        fax__Job_System__c jobItem
    ) {
        return new fax__Invoice_Line_Item__c(
            fax__Invoice__c = invoiceId,
            fax__Product__c = jobItem.fax__Product__c,
            fax__Qty__c = jobItem.fax__Quantity__c,
            fax__Unit_Price__c = jobItem.fax__Unit_Price__c,
            fax__Discount__c = jobItem.fax__Discount__c,
            Description__c = jobItem.fax__Product__r == null ? null : jobItem.fax__Product__r.Description,
            Include_In_Invoice__c = true,
            Job_Item_Lookup__c = jobItem.Id,
            Consolidated_Job__c = jobItem.fax__Job_New__c
        );
    }

    private static String buildJunctionKey(Id invoiceId, Id jobId) {
        return String.valueOf(invoiceId) + ':' + String.valueOf(jobId);
    }
}