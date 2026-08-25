public with sharing class JobInvoiceController {
    @AuraEnabled
    public static void deleteInvoiceForJob(Id jobId) {
        if (jobId == null) {
            throw new AuraHandledException('Job Id is required.');
        }

        List<fax__Invoice__c> invoices = [
            SELECT Id
            FROM fax__Invoice__c
            WHERE fax__Job__c = :jobId
            LIMIT 1
        ];

        if (invoices.isEmpty()) {
            return;
        }

        delete invoices;
    }
}