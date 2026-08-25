public with sharing class QuoteDocumentController {

    // ── Valid VF page names allowed for PDF generation ────────────────────────
    private static final Set<String> ALLOWED_PAGES = new Set<String>{
        'QuotePreview',
        'QuoteSummaryFormatPreview'
    };

    /**
     * Generates a QuoteDocument PDF from the specified Visualforce page.
     *
     * @param quoteId    - Id of the Quote record
     * @param pageFormat - VF page name: 'QuotePreview' or 'QuoteSummaryFormatPreview'
     *                     Defaults to 'QuotePreview' if blank or invalid.
     */
    @AuraEnabled
    public static Id generateQuoteDocument(Id quoteId, String pageFormat) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote Id is required');
        }

        // Sanitise / default the page name to prevent open-redirect via parameter
        String safePage = (String.isNotBlank(pageFormat) && ALLOWED_PAGES.contains(pageFormat))
            ? pageFormat
            : 'QuotePreview';

        try {
            Blob pdfBlob;

            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Mock PDF content');
            } else {
                PageReference pdfPage = new PageReference('/apex/' + safePage + '?id=' + quoteId);
                pdfBlob = pdfPage.getContentAsPDF();
            }

            QuoteDocument qDoc = new QuoteDocument();
            qDoc.QuoteId   = quoteId;
            qDoc.Document  = pdfBlob;
            insert qDoc;

            return qDoc.Id;

        } catch (Exception e) {
            throw new AuraHandledException('Error generating Quote PDF: ' + e.getMessage());
        }
    }


    @AuraEnabled(cacheable=true)
    public static QuoteDocument getQuoteDocumentDetails(Id quoteDocId) {
        return [
            SELECT Id, Name
            FROM QuoteDocument
            WHERE Id = :quoteDocId
            LIMIT 1
        ];
    }
}