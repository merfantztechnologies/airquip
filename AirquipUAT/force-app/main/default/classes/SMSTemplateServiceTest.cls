@isTest
private class SMSTemplateServiceTest {
    @isTest
    static void testBuild_TemplateMissing_ReturnsNull() {
        SMSTemplateService.clearCache();
        String msg = SMSTemplateService.build('NON_EXISTENT_TEMPLATE', new Map<String, String>{ 'X' => 'Y' });
        System.assertEquals(null, msg);
    }

    @isTest
    static void testBuild_WithInjectedTemplate_ReplacesPlaceholders() {
        SMSTemplateService.clearCache();
        SMS_Template__mdt tmpl = new SMS_Template__mdt();
        tmpl.DeveloperName = 'TEST_TEMPLATE';
        tmpl.Message_Body__c = 'Hello {CustomerName}, your job {JobNo} is ready.';

        SMSTemplateService.templateCache = new Map<String, SMS_Template__mdt>{
            'TEST_TEMPLATE' => tmpl
        };

        String msg = SMSTemplateService.build(
            'TEST_TEMPLATE',
            new Map<String, String>{
                'CustomerName' => 'Acme',
                'JobNo' => 'J-100'
            }
        );
        System.assertEquals('Hello Acme, your job J-100 is ready.', msg);
    }

    @isTest
    static void testBuild_BlankTemplateBody_ReturnsNull() {
        SMSTemplateService.clearCache();
        SMS_Template__mdt tmpl = new SMS_Template__mdt();
        tmpl.DeveloperName = 'BLANK_TEMPLATE';
        tmpl.Message_Body__c = '';

        SMSTemplateService.templateCache = new Map<String, SMS_Template__mdt>{
            'BLANK_TEMPLATE' => tmpl
        };

        String msg = SMSTemplateService.build('BLANK_TEMPLATE', new Map<String, String>{ 'A' => 'B' });
        System.assertEquals(null, msg);
    }
}