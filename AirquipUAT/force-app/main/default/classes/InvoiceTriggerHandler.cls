public with sharing class InvoiceTriggerHandler {

    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_IN_REVIEW = 'In Review';
    private static final String MAPPING_OBJECT = 'fax__Invoice__c';

    private static final Set<String> LINE_ITEM_DERIVED_FIELDS = new Set<String>{
        'Tax__c',
        'Sub_Total_Tax_Product__c',
        'fax__Grand_Total__c'
    };

    private static Set<String> getSyncFields() {
        return new MappingFieldLoader().loadSyncFields();
    }

    private static Set<Id> getInvoiceIdsWithLineItems(Set<Id> invoiceIds) {
        Set<Id> invoiceIdsWithLineItems = new Set<Id>();
        if (invoiceIds == null || invoiceIds.isEmpty()) {
            return invoiceIdsWithLineItems;
        }

        for (AggregateResult ar : [
            SELECT fax__Invoice__c invoiceId
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c IN :invoiceIds
            GROUP BY fax__Invoice__c
        ]) {
            invoiceIdsWithLineItems.add((Id) ar.get('invoiceId'));
        }
        return invoiceIdsWithLineItems;
    }

    public static void handleBeforeInsert(List<fax__Invoice__c> newList) {
        // Line items are added after insert; sync is evaluated on invoice update.
    }

    public static void handleBeforeUpdate(
        List<fax__Invoice__c> newList,
        Map<Id, fax__Invoice__c> oldMap
    ) {
        applySyncFlag(newList, oldMap);
    }

    public static void handleAfterInsert(List<fax__Invoice__c> newList) {
        syncInvoicesWithLineItems(newList);
    }

   public static void handleBeforeDelete(List<fax__Invoice__c> oldList) {
    Set<Id> jobIds = new Set<Id>();

    for (fax__Invoice__c invoice : oldList) {
        if (invoice.fax__Job__c != null) {
            jobIds.add(invoice.fax__Job__c);
        }
    }

    if (!jobIds.isEmpty()) {
        validateInvoiceDeletion(oldList, jobIds);
    }
}

private static void validateInvoiceDeletion(
    List<fax__Invoice__c> oldList,
    Set<Id> jobIds
) {
    Map<Id, fax__Job__c> jobMap = new Map<Id, fax__Job__c>(
        [
            SELECT Id, Invoice_Required__c
            FROM fax__Job__c
            WHERE Id IN :jobIds
        ]
    );

    for (fax__Invoice__c invoice : oldList) {
        if (invoice.fax__Job__c == null) {
            continue;
        }

        fax__Job__c job = jobMap.get(invoice.fax__Job__c);

        if (job != null && job.Invoice_Required__c == true) {
            invoice.addError(
                'This invoice cannot be deleted because the Job is marked as "Invoice Required". ' +
                'Please uncheck "Invoice Required" on the Job before deleting this invoice.'
            );
        }
    }
}
    
    private static void applySyncFlag(
        List<fax__Invoice__c> newList,
        Map<Id, fax__Invoice__c> oldMap
    ) {
        Set<String> syncFields = getSyncFields();
        Set<Id> candidateInvoiceIds = new Set<Id>();

        for (fax__Invoice__c inv : newList) {
            if (!isEligibleForQuickBooksSync(inv.fax__Status__c)) {
                continue;
            }

            fax__Invoice__c oldInv = oldMap.get(inv.Id);

            if (wasSyncFieldExplicitlyChanged(inv, oldInv)) {
                continue;
            }

            if (!shouldSyncOnUpdate(inv, oldInv, syncFields)) {
                continue;
            }

            candidateInvoiceIds.add(inv.Id);
        }

        setSyncFlagOnInvoices(newList, getInvoiceIdsWithLineItems(candidateInvoiceIds));
    }

    private static void syncInvoicesWithLineItems(List<fax__Invoice__c> newList) {
        Set<Id> eligibleInvoiceIds = new Set<Id>();
        for (fax__Invoice__c inv : newList) {
            if (isEligibleForQuickBooksSync(inv.fax__Status__c)) {
                eligibleInvoiceIds.add(inv.Id);
            }
        }

        Set<Id> invoiceIdsWithLineItems = getInvoiceIdsWithLineItems(eligibleInvoiceIds);
        if (invoiceIdsWithLineItems.isEmpty()) {
            return;
        }

        List<fax__Invoice__c> invoicesToUpdate = new List<fax__Invoice__c>();
        for (Id invoiceId : invoiceIdsWithLineItems) {
            invoicesToUpdate.add(new fax__Invoice__c(
                Id = invoiceId,
                Sync_to_Quickbooks__c = true
            ));
        }
        updateInvoicesForSync(invoicesToUpdate);
    }

    private static void setSyncFlagOnInvoices(
        List<fax__Invoice__c> newList,
        Set<Id> invoiceIdsWithLineItems
    ) {
        for (fax__Invoice__c inv : newList) {
            if (invoiceIdsWithLineItems.contains(inv.Id)) {
                inv.Sync_to_Quickbooks__c = true;
            }
        }
    }

    private static void updateInvoicesForSync(List<fax__Invoice__c> invoicesToUpdate) {
        if (invoicesToUpdate.isEmpty()) {
            return;
        }

        for (Database.SaveResult sr : Database.update(invoicesToUpdate, false)) {
            if (!sr.isSuccess()) {
                System.debug(
                    LoggingLevel.WARN,
                    'InvoiceTriggerHandler updateInvoicesForSync failed: ' + sr.getErrors()
                );
            }
        }
    }

    private static Boolean isEligibleForQuickBooksSync(String status) {
        return status != STATUS_DRAFT && status != STATUS_IN_REVIEW;
    }

    private static Boolean isStatusChanged(fax__Invoice__c newInv, fax__Invoice__c oldInv) {
        return newInv.fax__Status__c != oldInv.fax__Status__c;
    }

    private static Boolean wasSyncFieldExplicitlyChanged(
        fax__Invoice__c newInv,
        fax__Invoice__c oldInv
    ) {
        if (newInv.Sync_to_Quickbooks__c == null) {
            return false;
        }
        return newInv.Sync_to_Quickbooks__c != oldInv.Sync_to_Quickbooks__c;
    }

    private static Boolean isSyncFieldChanged(
        fax__Invoice__c newInv,
        fax__Invoice__c oldInv,
        Set<String> syncFields
    ) {
        for (String fieldName : syncFields) {
            Object newValue = newInv.get(fieldName);
            Object oldValue = oldInv.get(fieldName);

            if (newValue == null && oldValue != null) {
                continue;
            }

            if (newValue != oldValue) {
                return true;
            }
        }
        return false;
    }

    private static Boolean isLineItemDerivedFieldChanged(
        fax__Invoice__c newInv,
        fax__Invoice__c oldInv
    ) {
        Map<String, Object> newFields = newInv.getPopulatedFieldsAsMap();
        Map<String, Object> oldFields = oldInv.getPopulatedFieldsAsMap();

        for (String fieldName : LINE_ITEM_DERIVED_FIELDS) {
            Boolean newHasField = newFields.containsKey(fieldName);
            Boolean oldHasField = oldFields.containsKey(fieldName);

            if (!newHasField && !oldHasField) {
                continue;
            }

            Object newValue = newHasField ? newFields.get(fieldName) : oldInv.get(fieldName);
            Object oldValue = oldHasField ? oldFields.get(fieldName) : oldInv.get(fieldName);

            if (newValue == null && oldValue != null) {
                continue;
            }

            if (newValue != oldValue) {
                return true;
            }
        }
        return false;
    }

    private static Boolean shouldSyncOnUpdate(
        fax__Invoice__c newInv,
        fax__Invoice__c oldInv,
        Set<String> syncFields
    ) {
        return isStatusChanged(newInv, oldInv) ||
            isLineItemDerivedFieldChanged(newInv, oldInv) ||
            (!syncFields.isEmpty() && isSyncFieldChanged(newInv, oldInv, syncFields));
    }

    // SMS ROW 11 — Invoice Generated → SMS Customer
    // Template: SMSTemplateService.INVOICE_GENERATED
    // Placeholders: {CustomerName} {InvoiceNo} {Amount} {JobNo}
    //
    // FIX: Re-query Invoice with fax__Job__r.Name to get Job Number
    //      (String.valueOf(inv.fax__Job__c) returns Record ID not Job No)
    public static void sendSMSInvoiceGenerated(
        List<fax__Invoice__c> newList,
        Map<Id, fax__Invoice__c> oldMap
    ) {
        Set<Id> eligibleIds = new Set<Id>();
        for (fax__Invoice__c inv : newList) {
            fax__Invoice__c oldInv = oldMap != null ? oldMap.get(inv.Id) : null;

            Boolean justGenerated =
                (inv.fax__Status__c == 'Draft' || inv.fax__Status__c == 'Sent') &&
                (oldInv == null ||
                (oldInv.fax__Status__c != 'Draft' &&
                 oldInv.fax__Status__c != 'Sent'));

            if (justGenerated && inv.fax__Site__c != null)
                eligibleIds.add(inv.Id);
        }
        if (eligibleIds.isEmpty()) return;

        Map<Id, fax__Invoice__c> invoiceMap = new Map<Id, fax__Invoice__c>([
            SELECT Id, Name,
                   fax__Status__c,
                   fax__Grand_Total__c,
                   fax__Site__c,
                   fax__Job__c,
                   fax__Job__r.Name
            FROM   fax__Invoice__c
            WHERE  Id IN :eligibleIds
        ]);

        Set<Id> accountIds = new Set<Id>();
        for (fax__Invoice__c inv : invoiceMap.values()) {
            if (inv.fax__Site__c != null) accountIds.add(inv.fax__Site__c);
        }

        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Name, Phone FROM Account WHERE Id IN :accountIds
        ]);

        for (Id invId : eligibleIds) {
            fax__Invoice__c inv = invoiceMap.get(invId);
            if (inv == null) continue;

            Account acc = accountMap.get(inv.fax__Site__c);
            if (acc == null || String.isBlank(acc.Phone)) continue;

            String jobNo = (inv.fax__Job__c != null && inv.fax__Job__r.Name != null)
                ? inv.fax__Job__r.Name : 'N/A';

            String amount = inv.fax__Grand_Total__c != null
                ? String.valueOf(inv.fax__Grand_Total__c) : '0.00';

            System.debug('[InvoiceTriggerHandler] Row 11 | Invoice: ' + inv.Name
                + ' | Job: ' + jobNo + ' | Amount: ' + amount);

            String msg = SMSTemplateService.build(
                SMSTemplateService.INVOICE_GENERATED,
                new Map<String, String>{
                    'CustomerName' => nvl(acc.Name),
                    'InvoiceNo'    => nvl(inv.Name),
                    'Amount'       => amount,
                    'JobNo'        => jobNo
                }
            );
            if (String.isNotBlank(msg))
                RingCentralSMSService.sendSMS(acc.Phone, msg);
        }
    }

    private static String nvl(String val) {
        return String.isNotBlank(val) ? val : '';
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