public with sharing class ConsolidatedInvoiceJobTriggerHandler {
    public static void handleBeforeInsert(List<Consolidated_Invoice_Job__c> newRecords) {
        ConsolidatedInvoiceJobService.preventDoubleBilling(newRecords);
    }

    public static void handleAfterInsert(List<Consolidated_Invoice_Job__c> newRecords) {
        ConsolidatedInvoiceJobService.deleteIndividualJobInvoices(newRecords);
        ConsolidatedInvoiceJobService.createInvoiceLineItems(newRecords);
    }

    public static void handleBeforeDelete(List<Consolidated_Invoice_Job__c> oldRecords) {
        ConsolidatedInvoiceJobService.deleteInvoiceLineItems(oldRecords);
    }
}