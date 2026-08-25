public with sharing class DocumentService {
    private static final String INVOICE_PREVIEW_PREFIX = 'InvoicePreview_V';

    /*
    =============================================
    GENERATE PDF + STORE + LINK FILE
    =============================================
    */
    @AuraEnabled
    public static Id generateDocument(Id recordId, String vfPageName) {

        if (recordId == null || String.isBlank(vfPageName)) {
            throw new AuraHandledException('Record Id and VF Page Name are required');
        }

        try {

            Blob pdfBlob;

            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Mock PDF');
            } else {
                PageReference pdfPage = new PageReference('/apex/' + vfPageName + '?id=' + recordId);
                pdfBlob = pdfPage.getContentAsPDF();
            }

            ContentVersion cv = new ContentVersion();
            String docTitle = vfPageName + '_' + recordId;
            String pathOnClient = vfPageName + '.pdf';
           if (vfPageName == 'InvoicePreview') {

    fax__Invoice__c inv = [
        SELECT Name, fax__Site__r.Name
        FROM fax__Invoice__c
        WHERE Id = :recordId
        LIMIT 1
    ];

    Integer nextVersion = getNextInvoicePreviewVersion(recordId);
               
    String accountName = '';

    if (inv.fax__Site__r != null) {
        accountName = inv.fax__Site__r.Name;
    }

    /*
    =============================================
    REMOVE SPECIAL CHARACTERS
    =============================================
    */
    accountName = accountName.replaceAll('[^a-zA-Z0-9]', '');

    /*
    =============================================
    FILE NAME FORMAT:
    AccountName-InvoiceNumber
    =============================================
    */
    docTitle =
        accountName +
        '-' +
        inv.Name+ '_V' + String.valueOf(nextVersion);
               
    pathOnClient = docTitle + '.pdf';
}
            
            cv.Title = docTitle;
            cv.PathOnClient = pathOnClient;
            cv.VersionData = pdfBlob;
            insert cv;

            // Fetch ContentDocumentId
            cv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
            ];

            // Link file to record
            ContentDocumentLink link = new ContentDocumentLink();
            link.LinkedEntityId = recordId;
            link.ContentDocumentId = cv.ContentDocumentId;
            link.ShareType = 'V';
            link.Visibility = 'AllUsers';
            insert link;

            return cv.Id;

        } catch (Exception e) {
            throw new AuraHandledException('PDF generation failed: ' + e.getMessage());
        }
    }

   private static Integer getNextInvoicePreviewVersion(Id recordId) {

    Integer maxVersion = 0;

    for (ContentDocumentLink link : [

        SELECT ContentDocument.LatestPublishedVersion.Title
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :recordId

    ]) {

        String title =
            link.ContentDocument
                .LatestPublishedVersion
                .Title;

        if (String.isBlank(title)) {
            continue;
        }

        /*
        =============================================
        FIND LAST "_V"
        Example:
        INV-001_ABC_V1
        =============================================
        */
        Integer versionIndex =
            title.lastIndexOf('_V');

        if (versionIndex == -1) {
            continue;
        }

        try {

            String versionStr =
                title.substring(versionIndex + 2);

            Integer versionNum =
                Integer.valueOf(versionStr);

            maxVersion =
                Math.max(maxVersion, versionNum);

        } catch (Exception ex) {

            // Ignore invalid versions
        }
    }

    return maxVersion + 1;
}


    /*
    =============================================
    FETCH LATEST FILE FOR EMAIL ATTACHMENT
    =============================================
    */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getLatestFile(Id recordId) {

        if (recordId == null) {
            throw new AuraHandledException('Record Id is required');
        }

        try {

            ContentDocumentLink link = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId
                ORDER BY SystemModstamp DESC
                LIMIT 1
            ];

            ContentVersion version = [
                SELECT Id, Title, FileExtension, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId = :link.ContentDocumentId
                ORDER BY VersionNumber DESC
                LIMIT 1
            ];

            return new Map<String, String>{
                'name' => version.Title + '.' + version.FileExtension,
                'data' => EncodingUtil.base64Encode(version.VersionData)
            };

        } catch (Exception e) {
            throw new AuraHandledException('No document found: ' + e.getMessage());
        }
    }

}