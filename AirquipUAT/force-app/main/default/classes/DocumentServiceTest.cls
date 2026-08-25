/**
 * Tests for DocumentService (invoice PDF generation + latest file for email attachment).
 */
@isTest
private class DocumentServiceTest {

    @testSetup
    static void setupInvoice() {
        Account siteAcc = new Account(Name = 'Invoice Site Account');
        insert siteAcc;

        fax__Invoice__c inv = new fax__Invoice__c(fax__Site__c = siteAcc.Id);
        insert inv;
    }

    static fax__Invoice__c getTestInvoice() {
        return [
            SELECT Id, Name, fax__Site__r.Name
            FROM fax__Invoice__c
            WHERE fax__Site__r.Name = 'Invoice Site Account'
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
    }

    static String expectedInvoicePreviewTitle(fax__Invoice__c inv, Integer versionNumber) {
        String accountName = inv.fax__Site__r != null ? inv.fax__Site__r.Name : '';
        accountName = accountName.replaceAll('[^a-zA-Z0-9]', '');
        return accountName + '-' + inv.Name + '_V' + String.valueOf(versionNumber);
    }

    @isTest
    static void generateDocument_ThrowsWhenRecordIdNull() {
        try {
            DocumentService.generateDocument(null, 'InvoicePreview');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    @isTest
    static void generateDocument_ThrowsWhenVfPageNameBlank() {
        Account a = new Account(Name = 'DocSvc Acc');
        insert a;
        try {
            DocumentService.generateDocument(a.Id, '');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    @isTest
    static void generateDocument_InvoicePreview_UsesInvoiceNamingAndVersion() {
        fax__Invoice__c inv = getTestInvoice();

        Test.startTest();
        Id cvId = DocumentService.generateDocument(inv.Id, 'InvoicePreview');
        Test.stopTest();

        System.assertNotEquals(null, cvId);
        ContentVersion cv = [SELECT Title, PathOnClient FROM ContentVersion WHERE Id = :cvId];
        String expectedBase = expectedInvoicePreviewTitle(inv, 1);
        System.assertEquals(expectedBase, cv.Title);
        System.assertEquals(expectedBase + '.pdf', cv.PathOnClient);

        ContentDocumentLink cdl = [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :inv.Id
            LIMIT 1
        ];
        System.assertEquals(inv.Id, cdl.LinkedEntityId);
    }

    @isTest
    static void generateDocument_GenericVfPage_UsesDefaultNaming() {
        Account a = new Account(Name = 'Gen Acc');
        insert a;

        Test.startTest();
        Id cvId = DocumentService.generateDocument(a.Id, 'OtherVfPage');
        Test.stopTest();

        ContentVersion cv = [SELECT Title, PathOnClient FROM ContentVersion WHERE Id = :cvId];
        System.assertEquals('OtherVfPage_' + a.Id, cv.Title);
        System.assertEquals('OtherVfPage.pdf', cv.PathOnClient);
    }

    @isTest
    static void generateDocument_InvoicePreview_IncrementsVersionPerInvoice() {
        fax__Invoice__c inv = getTestInvoice();

        Test.startTest();
        Id firstCvId = DocumentService.generateDocument(inv.Id, 'InvoicePreview');
        Id secondCvId = DocumentService.generateDocument(inv.Id, 'InvoicePreview');
        Test.stopTest();

        Map<Id, ContentVersion> byId = new Map<Id, ContentVersion>(
            [SELECT Id, Title, PathOnClient FROM ContentVersion WHERE Id IN :new Set<Id>{ firstCvId, secondCvId }]
        );
        String v1 = expectedInvoicePreviewTitle(inv, 1);
        String v2 = expectedInvoicePreviewTitle(inv, 2);
        System.assertEquals(v1, byId.get(firstCvId).Title);
        System.assertEquals(v2, byId.get(secondCvId).Title);
        System.assertEquals(v2 + '.pdf', byId.get(secondCvId).PathOnClient);
    }

    @isTest
    static void getNextInvoicePreviewVersion_IgnoresMalformedTitles() {
        fax__Invoice__c inv = getTestInvoice();

        ContentVersion orphan = new ContentVersion(
            Title = 'No_Version_Index_Here',
            PathOnClient = 'orphan.pdf',
            VersionData = Blob.valueOf('x')
        );
        insert orphan;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :orphan.Id LIMIT 1].ContentDocumentId;

        ContentDocumentLink junkLink = new ContentDocumentLink(
            LinkedEntityId = inv.Id,
            ContentDocumentId = docId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        insert junkLink;

        Test.startTest();
        Id cvId = DocumentService.generateDocument(inv.Id, 'InvoicePreview');
        Test.stopTest();

        String expected = expectedInvoicePreviewTitle(inv, 1);
        System.assertEquals(expected, [SELECT Title FROM ContentVersion WHERE Id = :cvId].Title);
    }

    @isTest
    static void getLatestFile_ThrowsWhenRecordIdNull() {
        try {
            DocumentService.getLatestFile(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    @isTest
    static void getLatestFile_NoLink_Throws() {
        Account a = new Account(Name = 'No File');
        insert a;
        try {
            DocumentService.getLatestFile(a.Id);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    @isTest
    static void getLatestFile_ReturnsBase64AfterGenerate() {
        fax__Invoice__c inv = getTestInvoice();
        DocumentService.generateDocument(inv.Id, 'InvoicePreview');

        Test.startTest();
        Map<String, String> payload = DocumentService.getLatestFile(inv.Id);
        Test.stopTest();

        System.assert(payload.get('name').endsWith('.pdf'));
        System.assertNotEquals(null, payload.get('data'));
        System.assert(payload.get('data').length() > 0);
    }
}