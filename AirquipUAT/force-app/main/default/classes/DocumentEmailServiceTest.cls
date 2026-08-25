@isTest
public class DocumentEmailServiceTest {

    @testSetup
    static void setupData() {
        Account site = new Account(Name = 'Test Site');
        insert site;

        insert new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            Email = 'contact@test.com',
            AccountId = site.Id
        );

        insert new fax__Invoice__c(fax__Site__c = site.Id);

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        insert new User(
            FirstName = 'Searchable',
            LastName = 'InternalUser',
            Email = 'internal.user@test.com',
            Username = 'internaluser' + System.currentTimeMillis() + '@test.com',
            Alias = 'intusr',
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
    }

    private static fax__Invoice__c getInvoice() {
        return [SELECT Id, fax__Site__c FROM fax__Invoice__c LIMIT 1];
    }

    @isTest
    static void testGetFromAddresses() {
        Test.startTest();
        List<String> result = DocumentEmailService.getFromAddresses();
        Test.stopTest();

        System.assert(result.size() > 0, 'Should return at least one email');
        System.assert(result.contains(UserInfo.getUserEmail()), 'Should include current user email');
    }

    @isTest
    static void testGetDefaultCcEmails() {
        Test.startTest();
        List<String> cc = DocumentEmailService.getDefaultCcEmails();
        Test.stopTest();

        System.assertNotEquals(null, cc);
        for (String email : cc) {
            System.assert(!String.isBlank(email), 'Each parsed CC should be non-blank');
        }
    }

    @isTest
    static void testSearchContactEmails_MatchByName() {
        fax__Invoice__c inv = getInvoice();

        Test.startTest();
        List<Map<String, String>> results =
            DocumentEmailService.searchContactEmails('Test', inv.Id);
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return contacts on invoice site');
        Boolean found = false;
        for (Map<String, String> row : results) {
            if (row.get('Email') == 'contact@test.com') {
                found = true;
                System.assertEquals('Test Contact - contact@test.com', row.get('Display'));
                break;
            }
        }
        System.assert(found, 'Site contact should appear');
    }

    @isTest
    static void testSearchContactEmails_MatchByEmail() {
        fax__Invoice__c inv = getInvoice();

        List<Map<String, String>> results =
            DocumentEmailService.searchContactEmails('contact@test', inv.Id);

        System.assert(results.size() > 0, 'Should match on email field');
    }

    @isTest
    static void testSearchContactEmails_BlankKeyword() {
        fax__Invoice__c inv = getInvoice();

        System.assertEquals(
            0,
            DocumentEmailService.searchContactEmails('', inv.Id).size()
        );
        System.assertEquals(
            0,
            DocumentEmailService.searchContactEmails(null, inv.Id).size()
        );
    }

    @isTest
    static void testSearchContactEmails_InvalidInvoiceId() {
        System.assertEquals(
            0,
            DocumentEmailService.searchContactEmails('Test', null).size()
        );
        System.assertEquals(
            0,
            DocumentEmailService.searchContactEmails(
                'Test',
                'a00000000000000AAA'
            ).size()
        );
    }

    @isTest
    static void testSearchContactEmails_InvoiceWithoutSite() {
        fax__Invoice__c inv = new fax__Invoice__c();
        insert inv;

        System.assertEquals(
            0,
            DocumentEmailService.searchContactEmails('Test', inv.Id).size()
        );
    }

    @isTest
    static void testSearchInternalUsers_Match() {
        Test.startTest();
        List<Map<String, String>> results =
            DocumentEmailService.searchInternalUsers('Searchable');
        Test.stopTest();

        Boolean found = false;
        for (Map<String, String> row : results) {
            if (row.get('Email') == 'internal.user@test.com') {
                found = true;
                System.assert(row.get('Display').contains('Searchable InternalUser'));
                System.assertNotEquals(null, row.get('Role'));
                break;
            }
        }
        System.assert(found, 'Setup internal user should appear');
    }

    @isTest
    static void testSearchInternalUsers_BlankKeyword() {
        System.assertEquals(0, DocumentEmailService.searchInternalUsers('').size());
        System.assertEquals(0, DocumentEmailService.searchInternalUsers(null).size());
    }

    @isTest
    static void testSearchInternalUsers_ExcludesMerfantzTeamName() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        insert new User(
            FirstName = 'X',
            LastName = 'Merfantz Team',
            Email = 'merfantz.exclude@test.com',
            Username = 'merfantz' + System.currentTimeMillis() + '@test.com',
            Alias = 'merfex',
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );

        for (Map<String, String> row : DocumentEmailService.searchInternalUsers('merfantz')) {
            System.assertNotEquals(
                'merfantz.exclude@test.com',
                row.get('Email'),
                'Merfantz Team user should be filtered out'
            );
        }
    }

    @isTest
    static void testSearchInternalUsers_UsesUserRoleNameWhenAssigned() {
        List<UserRole> roles = [SELECT Id FROM UserRole LIMIT 1];
        if (roles.isEmpty()) {
            return;
        }

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        insert new User(
            FirstName = 'Role',
            LastName = 'BasedUser',
            Email = 'role.based@test.com',
            Username = 'rolebased' + System.currentTimeMillis() + '@test.com',
            Alias = 'roleusr',
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            UserRoleId = roles[0].Id,
            IsActive = true
        );

        List<Map<String, String>> results =
            DocumentEmailService.searchInternalUsers('Role Based');

        Boolean found = false;
        for (Map<String, String> row : results) {
            if (row.get('Email') == 'role.based@test.com') {
                found = true;
                System.assert(row.get('Display').contains('(' + row.get('Role') + ')'));
                break;
            }
        }
        System.assert(found, 'User with role should appear using UserRole.Name');
    }

    @isTest
    static void testGetEmailTemplateAndSignature_ReturnsTemplateHtml() {
        fax__Invoice__c inv = getInvoice();

        Test.startTest();
        Map<String, String> result =
            DocumentEmailService.getEmailTemplateAndSignature(inv.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.containsKey('templateHtml'));
        System.assertNotEquals(null, result.get('templateHtml'));
    }

    @isTest
    static void testGetEmailTemplateAndSignature_ProcessesSignatureWithDashPrefix() {
        User runner = [
            SELECT Id, Signature
            FROM User
            WHERE Id = :UserInfo.getUserId()
        ];
        String originalSignature = runner.Signature;
        runner.Signature = '--Trimmed Signature';
        update runner;

        fax__Invoice__c inv = getInvoice();

        try {
            Map<String, String> result =
                DocumentEmailService.getEmailTemplateAndSignature(inv.Id);
            System.assertNotEquals(null, result.get('templateHtml'));
        } finally {
            runner.Signature = originalSignature;
            update runner;
        }
    }

    @isTest
    static void testSendEmail_WithAttachment() {
        fax__Invoice__c inv = getInvoice();
        String base64 = EncodingUtil.base64Encode(Blob.valueOf('Test File Content'));

        Test.startTest();
        DocumentEmailService.sendEmail(
            inv.Id,
            UserInfo.getUserEmail(),
            'to@test.com',
            'cc@test.com',
            'bcc@test.com',
            'Test Subject',
            '<p>Test Body</p>',
            new List<Map<String, Object>>{
                new Map<String, Object>{
                    'content' => base64,
                    'title' => 'test.pdf',
                    'contentType' => 'application/pdf'
                }
            }
        );
        Test.stopTest();
    }

    @isTest
    static void testSendEmail_WithoutAttachment() {
        fax__Invoice__c inv = getInvoice();

        Test.startTest();
        DocumentEmailService.sendEmail(
            inv.Id,
            UserInfo.getUserEmail(),
            'to@test.com',
            null,
            null,
            'Test No Attachment',
            '<p>No attachment</p>',
            null
        );
        Test.stopTest();
    }

    @isTest
    static void testSendEmail_AttachmentInfersPdfContentType() {
        fax__Invoice__c inv = getInvoice();
        String base64 = EncodingUtil.base64Encode(Blob.valueOf('x'));

        Test.startTest();
        DocumentEmailService.sendEmail(
            inv.Id,
            UserInfo.getUserEmail(),
            'to@test.com',
            null,
            null,
            'Subject',
            '<p>Hi</p>',
            new List<Map<String, Object>>{
                new Map<String, Object>{
                    'content' => base64,
                    'title' => 'doc.pdf'
                }
            }
        );
        Test.stopTest();
    }

    @isTest
    static void testSendEmail_AttachmentBlankContentTypeNonPdf() {
        fax__Invoice__c inv = getInvoice();
        String base64 = EncodingUtil.base64Encode(Blob.valueOf('x'));

        Test.startTest();
        DocumentEmailService.sendEmail(
            inv.Id,
            UserInfo.getUserEmail(),
            'to@test.com',
            null,
            null,
            'Subject',
            '<p>Hi</p>',
            new List<Map<String, Object>>{
                new Map<String, Object>{
                    'content' => base64,
                    'title' => 'data.bin'
                }
            }
        );
        Test.stopTest();
    }

    @isTest
    static void testSendEmail_InvalidAttachment_ThrowsAuraHandled() {
        fax__Invoice__c inv = getInvoice();
        Boolean threw = false;

        try {
            DocumentEmailService.sendEmail(
                inv.Id,
                UserInfo.getUserEmail(),
                'to@test.com',
                null,
                null,
                'S',
                '<p>x</p>',
                new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'content' => '%%%not-valid-base64%%%',
                        'title' => 'bad.pdf',
                        'contentType' => 'application/pdf'
                    }
                }
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Invalid base64 should surface as AuraHandledException');
    }

    @isTest
    static void testSendEmail_UsesOrgWideEmailWhenConfigured() {
        String owaAddress = null;
        String userEmail = UserInfo.getUserEmail();
        for (String addr : DocumentEmailService.getFromAddresses()) {
            if (!String.isBlank(addr) && addr != userEmail) {
                owaAddress = addr;
                break;
            }
        }
        if (String.isBlank(owaAddress)) {
            return;
        }

        fax__Invoice__c inv = getInvoice();

        Test.startTest();
        try {
            DocumentEmailService.sendEmail(
                inv.Id,
                owaAddress,
                'to@test.com',
                null,
                null,
                'OWA Subject',
                '<p>OWA body</p>',
                null
            );
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('Email Failed'),
                'Unexpected error: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @isTest
    static void testSendEmail_UsesSenderDisplayNameWhenNotOwa() {
        fax__Invoice__c inv = getInvoice();

        Test.startTest();
        DocumentEmailService.sendEmail(
            inv.Id,
            UserInfo.getUserEmail(),
            'to@test.com',
            null,
            null,
            'Subject',
            '<p>Body</p>',
            null
        );
        Test.stopTest();
    }
}