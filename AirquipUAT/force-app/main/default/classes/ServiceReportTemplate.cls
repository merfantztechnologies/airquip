public class ServiceReportTemplate {

    @InvocableMethod(label='Send Service Report Email')
    public static void sendServiceReport(List<Id> jobIds) {

        if (jobIds == null || jobIds.isEmpty()) return;

        // Get Jobs
        List<fax__Job__c> jobs = [
            SELECT Id, Name
            FROM fax__Job__c
            WHERE Id IN :jobIds
        ];
        if (jobs.isEmpty()) return;

        Set<Id> jobIdSet = new Set<Id>();
        for (fax__Job__c j : jobs) {
            jobIdSet.add(j.Id);
        }

        // Get Files
        Map<Id, Id> jobToDoc = new Map<Id, Id>();
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :jobIdSet
        ]) {
            jobToDoc.put(cdl.LinkedEntityId, cdl.ContentDocumentId);
        }

        // Latest version per document
        Map<Id, ContentVersion> docToVer = new Map<Id, ContentVersion>();
        if (!jobToDoc.isEmpty()) {
            for (ContentVersion cv : [
                SELECT Title, VersionData, FileExtension, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :jobToDoc.values()
                ORDER BY CreatedDate DESC
            ]) {
                if (!docToVer.containsKey(cv.ContentDocumentId)) {
                    docToVer.put(cv.ContentDocumentId, cv);
                }
            }
        }

        // Get Email Template
        List<EmailTemplate> templates = [
            SELECT Id
            FROM EmailTemplate
            WHERE DeveloperName = :System.Label.Job_Completion_Template
            LIMIT 1
        ];
        if (templates.isEmpty()) return;

        Id templateId = templates[0].Id;

        // Org-Wide Email
        Id oweaId;
        List<OrgWideEmailAddress> oweaList = [
            SELECT Id
            FROM OrgWideEmailAddress
            WHERE Address = :System.Label.Org_Wide_Address
            LIMIT 1
        ];
        if (!oweaList.isEmpty()) {
            oweaId = oweaList[0].Id;
        }

        // 🔥 FIX: Split emails
        List<String> emailList = System.Label.Service_Report_User_Email.split(',');

        // Trim emails
        for (Integer i = 0; i < emailList.size(); i++) {
            emailList[i] = emailList[i].trim();
        }

        // 🔥 Find matching Users
        List<User> users = [
            SELECT Id, Email
            FROM User
            WHERE Email IN :emailList
        ];

        // Map email → User
        Map<String, User> emailToUser = new Map<String, User>();
        for (User usr : users) {
            emailToUser.put(usr.Email, usr);
        }

        // Pick primary user (required for template)
        User primaryUser;
        for (String email : emailList) {
            if (emailToUser.containsKey(email)) {
                primaryUser = emailToUser.get(email);
                break;
            }
        }

        // 🚨 Fallback (VERY IMPORTANT)
        if (primaryUser == null) {
            primaryUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        }

        // Prepare Emails
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (fax__Job__c job : jobs) {

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();

            // Attachment
            if (jobToDoc.containsKey(job.Id)) {
                ContentVersion cv = docToVer.get(jobToDoc.get(job.Id));
                if (cv != null) {
                    Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
                    att.setFileName(cv.Title + '.' + cv.FileExtension);
                    att.setBody(cv.VersionData);
                    mail.setFileAttachments(new List<Messaging.EmailFileAttachment>{ att });
                }
            }

            // ✅ REQUIRED for template
            mail.setTargetObjectId(primaryUser.Id);
            mail.setTreatTargetObjectAsRecipient(true);
            mail.setSaveAsActivity(false);

            // 🔥 Add remaining emails as CC
            List<String> ccEmails = new List<String>();
            for (String email : emailList) {
                if (email != primaryUser.Email) {
                    ccEmails.add(email);
                }
            }

            if (!ccEmails.isEmpty()) {
                mail.setCcAddresses(ccEmails);
            }

            mail.setWhatId(job.Id);
            mail.setTemplateId(templateId);

            if (oweaId != null) {
                mail.setOrgWideEmailAddressId(oweaId);
            }

            emails.add(mail);
        }

        // Send Emails
        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }
}