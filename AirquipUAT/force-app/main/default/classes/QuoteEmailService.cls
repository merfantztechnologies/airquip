public with sharing class QuoteEmailService {
    
    // ---------- Get From Addresses ----------
    @AuraEnabled(cacheable=true)
    public static List<String> getFromAddresses() {
        List<String> fromList = new List<String>();
        fromList.add(UserInfo.getUserEmail());
        
        for (OrgWideEmailAddress owa : [
            SELECT Address 
            FROM OrgWideEmailAddress 
            WHERE IsVerified = true 
            LIMIT 10
        ]) {
            fromList.add(owa.Address);
        }
        return fromList;
    }

    // ---------- Get Quote Email Template ----------
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getQuoteEmailTemplate(Id quoteId) {
        Map<String, String> result = new Map<String, String>{
            'subject' => '',
            'body' => ''
        };

        List<EmailTemplate> templates = [
            SELECT Id, Subject, HtmlValue, Body
            FROM EmailTemplate
            WHERE DeveloperName = 'Quote_Sent_to_Customer'
            LIMIT 1
        ];

        if (templates.isEmpty()) {
            return result;
        }

        EmailTemplate template = templates[0];
        Messaging.SingleEmailMessage rendered =
            Messaging.renderStoredEmailTemplate(template.Id, null, quoteId);

        String renderedSubject = rendered.getSubject();
        String renderedBody = rendered.getHtmlBody();

        result.put(
            'subject',
            String.isBlank(renderedSubject) ? template.Subject : renderedSubject
        );
        result.put(
            'body',
            String.isBlank(renderedBody)
                ? (template.HtmlValue != null ? template.HtmlValue : template.Body)
                : renderedBody
        );

        return result;
    }

    // ---------- Send Email ----------
    @AuraEnabled
    public static void sendQuoteEmail(
        Id quoteId,
        String fromAddress,
        String toAddresses,
        String ccAddresses,
        String bccAddresses,
        String subject,
        String bodyHtml,
        List<Map<String, Object>> attachmentsJson
    ) {
        try {
            // ---------- Decide Signature ----------
            String signatureToUse = getDefaultSignature();

            // ---------- Final Body ----------
            String finalBody = String.isBlank(bodyHtml) ? '' : bodyHtml;
            
            // Safety: Append signature again if missing
            if (String.isNotBlank(signatureToUse) && 
                !finalBody.contains(signatureToUse)) {
                
                finalBody += '<br/><br/>' + signatureToUse;
            }

            // ---------- Attachments ----------
            List<Messaging.EmailFileAttachment> emailAttachments = new List<Messaging.EmailFileAttachment>();
            
            if (attachmentsJson != null) {
                for (Map<String, Object> att : attachmentsJson) {
                    if (att.containsKey('content')) {
                        Messaging.EmailFileAttachment efa = new Messaging.EmailFileAttachment();
                        
                        String base64Data = (String) att.get('content');
                        String name = (String) att.get('title');
                        
                        name = name.substringBeforeLast('_');
                        efa.fileName = name;
                        efa.body = EncodingUtil.base64Decode(base64Data);
                        
                        emailAttachments.add(efa);
                    }
                }
            }

            // ---------- Email ----------
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setUseSignature(false); // we handle manually
            
            if (!String.isBlank(toAddresses)) {
                mail.setToAddresses(toAddresses.split(','));
            }
            if (!String.isBlank(ccAddresses)) {
                mail.setCcAddresses(ccAddresses.split(','));
            }
            if (!String.isBlank(bccAddresses)) {
                mail.setBccAddresses(bccAddresses.split(','));
            }

            // ---------- From Address ----------
            if (!String.isBlank(fromAddress)) {
                Id owaId = getOrgWideId(fromAddress);
                
                if (owaId != null) {
                    mail.setOrgWideEmailAddressId(owaId);
                } else {
                    mail.setReplyTo(fromAddress);
                }
            }

            if (!emailAttachments.isEmpty()) {
                mail.setFileAttachments(emailAttachments);
            }

            // ---------- Set Content ----------
            mail.setSubject(subject);
            mail.setHtmlBody(finalBody);
            mail.setSaveAsActivity(true);
            mail.setWhatId(quoteId);

            // ---------- Send ----------
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        } catch (Exception e) {
            throw new AuraHandledException('Failed to send email: ' + e.getMessage());
        }
    }

    // ---------- Helper ----------
    private static String getDefaultSignature() {
        return
            '<div style="font-family:Arial, sans-serif; font-size:12px; line-height:1.4;">' +
            '</div>';
    }

    private static Id getOrgWideId(String email) {
        for (OrgWideEmailAddress owa : [
            SELECT Id, Address 
            FROM OrgWideEmailAddress
        ]) {
            if (owa.Address == email) return owa.Id;
        }
        return null;
    }

    // ---------- Search Emails ----------
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchEmails(String keyword) {
        if (String.isBlank(keyword)) return new List<Map<String, String>>();
        
        List<Map<String, String>> results = new List<Map<String, String>>();
        Integer maxResults = 8;
        
        for (Contact c : [
            SELECT Name, Email 
            FROM Contact 
            WHERE Email != null 
            AND (Name LIKE :('%' + keyword + '%') OR Email LIKE :('%' + keyword + '%')) 
            LIMIT :maxResults
        ]) {
            results.add(new Map<String, String>{
                'Name' => c.Name, 
                'Email' => c.Email
            });
        }
        
        if (results.size() < maxResults) {
            Integer remaining = maxResults - results.size();
            
            for (User u : [
                SELECT Name, Email 
                FROM User 
                WHERE Email != null 
                AND (Name LIKE :('%' + keyword + '%') OR Email LIKE :('%' + keyword + '%')) 
                LIMIT :remaining
            ]) {
                results.add(new Map<String, String>{
                    'Name' => u.Name, 
                    'Email' => u.Email
                });
            }
        }
        
        return results;
    }

    // ---------- Get Latest Quote File ----------
    @AuraEnabled
    public static Map<String, String> getLatestQuoteFile(Id quoteId) {

        List<QuoteDocument> quoteDocs = [
            SELECT ContentVersionDocumentId
            FROM QuoteDocument
            WHERE QuoteId = :quoteId 
            AND ContentVersionDocumentId != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        
        if (quoteDocs.isEmpty()) return null;
        
        ContentVersion version = [
            SELECT Title, FileExtension, VersionData
            FROM ContentVersion
            WHERE Id = :quoteDocs[0].ContentVersionDocumentId
            LIMIT 1
        ];
        
        return new Map<String, String>{
            'name' => version.Title + '.' + version.FileExtension,
            'data' => EncodingUtil.base64Encode(version.VersionData)
        };
    }
}