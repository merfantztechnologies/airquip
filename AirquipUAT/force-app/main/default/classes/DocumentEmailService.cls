public with sharing class DocumentEmailService {

    /*
    =============================================
    FROM ADDRESSES
    =============================================
    */
    @AuraEnabled(cacheable=true)
    public static List<String> getFromAddresses() {

        List<String> fromList = new List<String>();

        // Current User Email
        fromList.add(UserInfo.getUserEmail());

        // Org Wide Emails
        for (OrgWideEmailAddress owa : [
            SELECT Address
            FROM OrgWideEmailAddress
            WHERE IsAllowAllProfiles = true
        ]) {
            fromList.add(owa.Address);
        }

        return fromList;
    }


    /*
    =============================================
    DEFAULT CC EMAILS
    =============================================
    */
    @AuraEnabled(cacheable=true)
public static List<String> getDefaultCcEmails() {

    List<String> emails = new List<String>();

    // Get emails from Custom Label
    String ccEmails = System.Label.Default_CC_Emails;

    if (!String.isBlank(ccEmails)) {

        // Split by comma
        for (String email : ccEmails.split(',')) {

            email = email.trim();

            if (!String.isBlank(email)) {
                emails.add(email);
            }
        }
    }

    return emails;
}


    /*
    =============================================
    SEARCH CONTACT EMAILS
    Used for TO Address
    =============================================
    */
   @AuraEnabled(cacheable=true)
public static List<Map<String, String>> searchContactEmails(String keyword, Id invoiceId) {
    if (String.isBlank(keyword)) {
        return new List<Map<String, String>>();
    }

    List<fax__Invoice__c> invoices = [
        SELECT fax__Site__c 
        FROM fax__Invoice__c 
        WHERE Id = :invoiceId
        LIMIT 1
    ];
    
    System.debug('Invoice ID: ' + invoiceId);
    System.debug('Site (Account) ID: ' + (invoices.isEmpty() ? 'NOT FOUND' : invoices[0].fax__Site__c));

    if (invoices.isEmpty() || invoices[0].fax__Site__c == null) {
        return new List<Map<String, String>>();
    }

    Id accountId = invoices[0].fax__Site__c;

    List<Map<String, String>> results = new List<Map<String, String>>();
    for (Contact c : [
        SELECT Id, Name, Email
        FROM Contact
        WHERE Email != null
        AND AccountId = :accountId
        AND (
            Name LIKE :('%' + keyword + '%')
            OR Email LIKE :('%' + keyword + '%')
        )
        ORDER BY Name
        LIMIT 10
    ]) {
        results.add(new Map<String, String>{
            'Name' => c.Name,
            'Email' => c.Email,
            'Display' => c.Name + ' - ' + c.Email
        });
    }

    System.debug('Results count: ' + results.size());
    return results;
}


    /*
    =============================================
    SEARCH INTERNAL USERS
    Used for CC / BCC
    =============================================
    */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchInternalUsers(String keyword) {

        if (String.isBlank(keyword)) {
            return new List<Map<String, String>>();
        }

        List<Map<String, String>> results =
            new List<Map<String, String>>();

        for (User u : [
            SELECT Id,
                   Name,
                   Email,
                   UserRole.Name,
                   Profile.Name
            FROM User
            WHERE IsActive = true
            AND Email != null
            AND (
                Name LIKE :('%' + keyword + '%')
                OR Email LIKE :('%' + keyword + '%')
            )
            ORDER BY Name
            LIMIT 10
        ]) {

            // Exclude Merfantz Team
            if (
                u.Name != null &&
                u.Name.toLowerCase().contains('merfantz team')
            ) {
                continue;
            }

            String roleName = '';

            if (u.UserRole != null) {
                roleName = u.UserRole.Name;
            } else {
                roleName = u.Profile.Name;
            }

            results.add(new Map<String, String>{
                'Name' => u.Name,
                'Email' => u.Email,
                'Role' => roleName,
                'Display' =>
                    u.Name +
                    ' (' + roleName + ')' +
                    ' - ' +
                    u.Email
            });
        }

        return results;
    }


    /*
    =============================================
    SEND EMAIL
    =============================================
    */
  @AuraEnabled
    public static void sendEmail(
        Id recordId,
        String fromAddress,
        String toAddresses,
        String ccAddresses,
        String bccAddresses,
        String subject,
        String bodyHtml,
        List<Map<String, Object>> attachmentsJson
    ) {
        try {
            List<Messaging.EmailFileAttachment> emailAttachments = new List<Messaging.EmailFileAttachment>();

            // =============================================
            // 1. PREPARE ATTACHMENTS FOR THE OUTBOUND EMAIL
            // =============================================
            if (attachmentsJson != null && !attachmentsJson.isEmpty()) {
                for (Map<String, Object> att : attachmentsJson) {
                    Messaging.EmailFileAttachment efa = new Messaging.EmailFileAttachment();
                    String base64Data = (String) att.get('content');
                    String name = (String) att.get('title');
                    String contentType = (String) att.get('contentType');

                    if (String.isBlank(contentType)) {
                        contentType = (name != null && name.toLowerCase().endsWith('.pdf')) 
                            ? 'application/pdf' 
                            : 'application/octet-stream';
                    }

                    efa.setFileName(name);
                    efa.setBody(EncodingUtil.base64Decode(base64Data));
                    efa.setContentType(contentType);
                    emailAttachments.add(efa);
                }
            }

            // =============================================
            // 2. SETUP & SEND THE EMAIL
            // =============================================
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setUseSignature(false);
            
            if (String.isNotBlank(toAddresses)) mail.setToAddresses(toAddresses.split(','));
            if (String.isNotBlank(ccAddresses)) mail.setCcAddresses(ccAddresses.split(','));
            if (String.isNotBlank(bccAddresses)) mail.setBccAddresses(bccAddresses.split(','));

            if (String.isNotBlank(fromAddress)) {
                // Assuming you have this helper method elsewhere in your class
                Id owaId = getOrgWideId(fromAddress);
                if (owaId != null) {
                    mail.setOrgWideEmailAddressId(owaId);
                } else {
                    mail.setSenderDisplayName(UserInfo.getName());
                }
            }

            mail.setSubject(String.isNotBlank(subject) ? subject : 'Your Invoice is Ready!');
            mail.setHtmlBody(bodyHtml);
            mail.setSaveAsActivity(true);
            mail.setWhatId(recordId);

            if (!emailAttachments.isEmpty()) {
                mail.setFileAttachments(emailAttachments);
            }

            // Send the email (This automatically creates the EmailMessage record)
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

            // =============================================
            // 3. LINK FILES TO THE SAVED EMAILMESSAGE
            // =============================================
            if (String.isNotBlank(recordId)) {
                
                // Query the newly generated EmailMessage record
                List<EmailMessage> newEmails = [
                    SELECT Id FROM EmailMessage 
                    WHERE RelatedToId = :recordId 
                    ORDER BY CreatedDate DESC 
                    LIMIT 1
                ];

                if (!newEmails.isEmpty()) {
                    Id emailMessageId = newEmails[0].Id;
                    
                    // If we had base64 files, save them and link to the EmailMessage
                    if (attachmentsJson != null && !attachmentsJson.isEmpty()) {
                        List<ContentVersion> cvListToInsert = new List<ContentVersion>();
                        
                        for (Map<String, Object> att : attachmentsJson) {
                            String base64Data = (String) att.get('content');
                            String name = (String) att.get('title');
                            
                            ContentVersion cv = new ContentVersion();
                            cv.Title = name;
                            cv.PathOnClient = name;
                            cv.VersionData = EncodingUtil.base64Decode(base64Data);
                            // Setting FirstPublishLocationId automatically creates the 
                            // ContentDocumentLink to the EmailMessage!
                            cv.FirstPublishLocationId = emailMessageId; 
                            
                            cvListToInsert.add(cv);
                        }
                        
                        // Insert standard files so they appear on the Email Activity timeline
                        insert cvListToInsert;
                    }
                }

                // =============================================
                // 4. UPDATE INVOICE STATUS
                // =============================================
                List<fax__Invoice__c> invoices = [
                    SELECT Id, fax__Status__c 
                    FROM fax__Invoice__c 
                    WHERE Id = :recordId 
                    LIMIT 1
                ];

                if (!invoices.isEmpty()) {
                    invoices[0].fax__Status__c = 'Sent to Customer';
                    update invoices;
                }
            }

        } catch (Exception e) {
            throw new AuraHandledException('Email Failed: ' + e.getMessage());
        }
    }
    
    // Helper method stub
    private static Id getOrgWideId(String fromAddress) {
        List<OrgWideEmailAddress> owaList = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :fromAddress LIMIT 1];
        return owaList.isEmpty() ? null : owaList[0].Id;
    }

   
   /*
=============================================
GET EMAIL TEMPLATE + USER SIGNATURE
=============================================
*/
@AuraEnabled(cacheable=true)
public static Map<String, String> getEmailTemplateAndSignature(Id recordId) {

    Map<String, String> result = new Map<String, String>();

    // Fetch Email Template
    List<EmailTemplate> templates = [
        SELECT Id, Subject, HtmlValue, Body
        FROM EmailTemplate
        WHERE DeveloperName = 'Invoice_Sent_to_Customer'
        LIMIT 1
    ];

    String templateHtml = '';

    if (!templates.isEmpty()) {
    EmailTemplate tmpl = templates[0];

    Messaging.SingleEmailMessage rendered =
        Messaging.renderStoredEmailTemplate(
            tmpl.Id,
            null,
            recordId
        );

    templateHtml = rendered.getHtmlBody();

    // Fallback to raw HtmlValue if rendering returns empty
    if (String.isBlank(templateHtml)) {
        templateHtml = tmpl.HtmlValue != null
            ? tmpl.HtmlValue
            : tmpl.Body;
    }

    // Trim AFTER fallback logic, not before
    templateHtml = templateHtml.trim();
}

    // Fetch Current User Signature
    User currentUser = [
        SELECT Id, Signature
        FROM User
        WHERE Id = :UserInfo.getUserId()
        LIMIT 1
    ];

    String signature = '';
if (currentUser.Signature != null) {
    signature = currentUser.Signature;
    
    // Remove the leading '--' separator Salesforce auto-prepends
    if (signature.startsWith('--')) {
        signature = signature.substringAfter('--').trim();
    }
}

    result.put('templateHtml', templateHtml);
    //result.put('signature', signature);

    return result;
}
}