/**
 * QuickBooks Payment -> Salesforce Payment sync (Fixed).
 * Prefers fax__Payment__c / fax__Invoice__c so Payment.Invoice lookup types match.
 * Supports:
 *  - One Invoice <- many QB Payments (one SF Payment per QB Payment Id + Invoice)
 *  - One QB Payment -> many Invoices (one SF Payment row per LinkedTxn Invoice application)
 * After Payment upsert, refreshes Invoice fax__Status__c to Paid / Partially Paid / Over Due from QB Balance.
 * One QuickBooks page is processed per execute chunk for callout/DML safety.
 *
 * Run: Database.executeBatch(new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{'fax__Invoice__c'}), 1);
 * Or:  QuickBooksPaymentSyncBatchFixed.runBatch();
 */
public without sharing class QuickBooksPaymentSyncBatchFixed
implements Database.Batchable<Integer>, Database.Stateful, Database.AllowsCallouts, Schedulable {

    private static final String APP_NAME = 'QuickBook';
    private static final Integer PAGE_SIZE = 50;
    private static final Integer MAX_PAGES = 20;
    public static final Integer RECOMMENDED_BATCH_SIZE = 1;

    /** Prefer FieldAx core (fax__) first — matches Airquip Invoice/Payment package objects. */
    private static final List<String> PAYMENT_OBJECT_CANDIDATES = new List<String>{
        'fax__Payment__c', 'faxa__Payment__c', 'Payment__c', 'Fax__Payment__c'
    };
    private static final List<String> INVOICE_OBJECT_CANDIDATES = new List<String>{
        'fax__Invoice__c', 'faxa__Invoice__c', 'Invoice__c', 'Fax__Invoice__c'
    };

    private final String paymentObjectNameHint;
    private final List<String> invoiceObjectNameHints;
    private final Boolean useSandbox;

    private String resolvedPaymentObjectName;
    private List<String> resolvedInvoiceObjectNames;

    private Integer totalQbPaymentsFetched = 0;
    private Integer totalPaymentsUpserted = 0;
    private Integer totalTrackingLogsWritten = 0;
    private Integer totalApiQueryFailures = 0;
    private Integer totalPaymentsUnchanged = 0;
    private Integer totalPaymentsQueuedForUpdate = 0;
    private Integer totalPaymentsQueuedForInsert = 0;
    private Integer totalPaymentsMissingInvoiceLink = 0;
    private Integer totalInvoicesStatusUpdated = 0;
    private String batchSkipReason;

    public QuickBooksPaymentSyncBatchFixed() {
        this(null, null, null);
    }

    public QuickBooksPaymentSyncBatchFixed(String paymentObjectName, List<String> invoiceObjectNames) {
        this(paymentObjectName, invoiceObjectNames, null);
    }

    public QuickBooksPaymentSyncBatchFixed(String paymentObjectName, List<String> invoiceObjectNames, Boolean useSandbox) {
        this.paymentObjectNameHint = String.isNotBlank(paymentObjectName) ? paymentObjectName.trim() : null;
        this.invoiceObjectNameHints = (invoiceObjectNames == null || invoiceObjectNames.isEmpty())
            ? INVOICE_OBJECT_CANDIDATES.clone()
            : invoiceObjectNames.clone();
        this.useSandbox = useSandbox != null ? useSandbox : [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        faxa__External_App__c app = getQuickBooksApp();
        if (app == null) {
            batchSkipReason = 'QuickBook External App not found.';
            throw new QuickBooksPaymentSyncBatchFixedException(batchSkipReason);
        }
        if (app.faxa__Authentication_Status__c != 'Successful') {
            batchSkipReason = 'QuickBook authentication status is not Successful.';
            throw new QuickBooksPaymentSyncBatchFixedException(batchSkipReason);
        }

        resolvedPaymentObjectName = resolvePaymentObjectName();
        resolvedInvoiceObjectNames = resolveInvoiceObjectNames();
        if (String.isBlank(resolvedPaymentObjectName)) {
            batchSkipReason = 'No supported Salesforce Payment object was found.';
            throw new QuickBooksPaymentSyncBatchFixedException(batchSkipReason);
        }

        List<Integer> pages = new List<Integer>();
        Integer count = Test.isRunningTest() ? 1 : MAX_PAGES;
        for (Integer i = 1; i <= count; i++) {
            pages.add(i);
        }
        return pages;
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        faxa__External_App__c app = getQuickBooksApp();
        if (app == null) {
            recordBatchSkipReason('QuickBook External App not found in execute.');
            return;
        }
        if (String.isBlank(app.faxa__Realm_ID__c) || String.isBlank(app.faxa__Access_Token__c)) {
            recordBatchSkipReason('QuickBooks Realm Id or Access Token is blank.');
            return;
        }

        if (String.isBlank(resolvedPaymentObjectName)) {
            resolvedPaymentObjectName = resolvePaymentObjectName();
        }
        if (resolvedInvoiceObjectNames == null || resolvedInvoiceObjectNames.isEmpty()) {
            resolvedInvoiceObjectNames = resolveInvoiceObjectNames();
        }
        if (String.isBlank(resolvedPaymentObjectName)) {
            recordBatchSkipReason('No supported Salesforce Payment object was found.');
            return;
        }

        String baseUrl = useSandbox
            ? 'https://sandbox-quickbooks.api.intuit.com'
            : 'https://quickbooks.api.intuit.com';

        Integer pageNum = scope[0];
        processQuickBooksPaymentPage(
            pageNum,
            app,
            resolvedPaymentObjectName,
            baseUrl,
            app.faxa__Realm_ID__c,
            app.faxa__Access_Token__c
        );
    }

    @TestVisible
    private void runNullPageForTest() {
        processQuickBooksPaymentPage(null, null, resolvedPaymentObjectName, 'https://quickbooks.api.intuit.com', 'realm', 'token');
    }

    private void processQuickBooksPaymentPage(
        Integer pageNum,
        faxa__External_App__c app,
        String paymentObjectName,
        String baseUrl,
        String realmId,
        String accessToken
    ) {
        if (pageNum == null) {
            return;
        }

        PaymentObjectConfig paymentConfig = describePaymentObject(paymentObjectName);
        if (paymentConfig == null) {
            recordBatchSkipReason('Payment object could not be described: ' + paymentObjectName);
            return;
        }

        List<Map<String, Object>> qbPayments = fetchQuickBooksPaymentsForPage(baseUrl, realmId, accessToken, pageNum);
        if (qbPayments.isEmpty()) {
            return;
        }
        totalQbPaymentsFetched += qbPayments.size();

        Set<String> qbPaymentIds = new Set<String>();
        Set<String> qbInvoiceIds = new Set<String>();
        Map<String, List<PaymentInvoiceApplication>> applicationsByQbPaymentId =
            new Map<String, List<PaymentInvoiceApplication>>();
        for (Map<String, Object> qbPayment : qbPayments) {
            if (qbPayment.get('Id') == null) {
                continue;
            }
            String qbPaymentId = String.valueOf(qbPayment.get('Id')).trim();
            if (String.isBlank(qbPaymentId)) {
                continue;
            }
            qbPaymentIds.add(qbPaymentId);
            List<PaymentInvoiceApplication> applications = extractInvoiceApplicationsFromPayment(qbPayment);
            applicationsByQbPaymentId.put(qbPaymentId, applications);
            for (PaymentInvoiceApplication application : applications) {
                if (application != null && String.isNotBlank(application.qbInvoiceId)) {
                    qbInvoiceIds.add(application.qbInvoiceId);
                }
            }
        }

        // Keyed by QB Payment Id + SF Invoice Id so one QB payment can map to many SF Payments.
        Map<String, SObject> existingPaymentsByCompositeKey =
            loadExistingPaymentsByCompositeKey(paymentConfig, qbPaymentIds);
        Map<String, InvoiceMatch> invoiceByQbId = loadInvoicesByQuickBooksId(qbInvoiceIds, paymentConfig);
        // Callouts before any DML: cache QB Invoice payloads for status derivation.
        Map<String, Map<String, Object>> qbInvoicePayloadByTxnId = fetchQuickBooksInvoicesByIds(
            qbInvoiceIds,
            baseUrl,
            realmId,
            accessToken
        );
        List<SObject> toInsert = new List<SObject>();
        List<SObject> toUpdate = new List<SObject>();
        List<PaymentSyncTrackingRequest> tracking = new List<PaymentSyncTrackingRequest>();
        Map<Id, String> invoiceIdToQbTxnId = new Map<Id, String>();

        for (Map<String, Object> qbPayment : qbPayments) {
            String qbPaymentId = qbPayment.get('Id') == null ? null : String.valueOf(qbPayment.get('Id')).trim();
            if (String.isBlank(qbPaymentId)) {
                continue;
            }

            List<PaymentInvoiceApplication> applications = applicationsByQbPaymentId.get(qbPaymentId);
            if (applications == null || applications.isEmpty()) {
                totalPaymentsMissingInvoiceLink++;
                tracking.add(new PaymentSyncTrackingRequest(
                    app != null ? app.Id : null,
                    null,
                    paymentObjectName,
                    'QuickBooks Payment ' + qbPaymentId + ' skipped because it has no Invoice LinkedTxn lines.',
                    false
                ));
                continue;
            }

            for (PaymentInvoiceApplication application : applications) {
                if (application == null || String.isBlank(application.qbInvoiceId)) {
                    continue;
                }
                String qbInvoiceId = application.qbInvoiceId;
                InvoiceMatch invoiceMatch = invoiceByQbId.get(qbInvoiceId);
                String compositeKey = invoiceMatch == null
                    ? null
                    : buildPaymentCompositeKey(qbPaymentId, invoiceMatch.invoiceId);
                SObject existingPayment = String.isBlank(compositeKey)
                    ? null
                    : existingPaymentsByCompositeKey.get(compositeKey);
                SObject paymentRecord = buildPaymentRecord(
                    paymentConfig,
                    qbPayment,
                    qbPaymentId,
                    qbInvoiceId,
                    application.amount,
                    invoiceMatch,
                    existingPayment
                );

                if (paymentRecord == null) {
                    totalPaymentsMissingInvoiceLink++;
                    tracking.add(new PaymentSyncTrackingRequest(
                        app != null ? app.Id : null,
                        invoiceMatch != null ? invoiceMatch.invoiceId : null,
                        invoiceMatch != null ? invoiceMatch.objectName : paymentObjectName,
                        'QuickBooks Payment ' + qbPaymentId
                            + ' skipped for Invoice ' + qbInvoiceId
                            + ' because no Salesforce Invoice match was found.',
                        false
                    ));
                    continue;
                }

                if (invoiceMatch != null) {
                    invoiceIdToQbTxnId.put(invoiceMatch.invoiceId, qbInvoiceId);
                }

                if (existingPayment == null) {
                    toInsert.add(paymentRecord);
                    totalPaymentsQueuedForInsert++;
                    // Prevent duplicate inserts in the same page for the same QB Payment + Invoice.
                    if (String.isNotBlank(compositeKey)) {
                        existingPaymentsByCompositeKey.put(compositeKey, paymentRecord);
                    }
                } else if (hasChanges(paymentConfig, paymentRecord, existingPayment)) {
                    paymentRecord.put('Id', existingPayment.Id);
                    toUpdate.add(paymentRecord);
                    totalPaymentsQueuedForUpdate++;
                } else {
                    totalPaymentsUnchanged++;
                }
            }
        }

        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            recordResults(results, toInsert, app != null ? app.Id : null, paymentConfig.objectName, tracking, false);
        }
        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            recordResults(results, toUpdate, app != null ? app.Id : null, paymentConfig.objectName, tracking, true);
        }
        flushPaymentSyncTracking(tracking);
        // After Payment DML: refresh Invoice fax__Status__c (Paid / Partially Paid / Over Due) from QB Balance + SF amounts.
        updateInvoiceStatusesFromPayments(invoiceIdToQbTxnId, qbInvoicePayloadByTxnId);
    }

    @TestVisible
    private Integer fetchPageCountForTest(Integer pageNum) {
        return fetchQuickBooksPaymentsForPage('https://quickbooks.api.intuit.com', 'realm', 'token', pageNum).size();
    }

    private List<Map<String, Object>> fetchQuickBooksPaymentsForPage(String baseUrl, String realmId, String accessToken, Integer pageNum) {
        List<Map<String, Object>> payments = new List<Map<String, Object>>();
        if (pageNum == null || pageNum < 1) {
            return payments;
        }

        Integer startPos = ((pageNum - 1) * PAGE_SIZE) + 1;
        String query = 'select * from Payment startposition ' + startPos + ' maxresults ' + PAGE_SIZE;
        String endpoint = baseUrl + '/v3/company/' + realmId + '/query?query=' + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setTimeout(60000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            totalApiQueryFailures++;
            // Avoid DML here so subsequent callouts in the same transaction remain valid.
            System.debug(LoggingLevel.ERROR,
                'QuickBooksPaymentSyncBatchFixed: Payment query failed status='
                + res.getStatusCode() + ' page=' + pageNum);
            return payments;
        }

        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> qr = root == null ? null : (Map<String, Object>) root.get('QueryResponse');
        if (qr == null || qr.get('Payment') == null) {
            return payments;
        }

        Object payload = qr.get('Payment');
        if (payload instanceof List<Object>) {
            for (Object row : (List<Object>) payload) {
                if (row instanceof Map<String, Object>) {
                    payments.add((Map<String, Object>) row);
                }
            }
        } else if (payload instanceof Map<String, Object>) {
            payments.add((Map<String, Object>) payload);
        }
        return payments;
    }

    /**
     * Callout-only: load QB Invoice Balance/TotalAmt/DueDate for status updates.
     * Uses Query API in chunks to stay within callout limits (batch size = 1 page).
     */
    @TestVisible
    private Map<String, Map<String, Object>> fetchQuickBooksInvoicesByIds(
        Set<String> qbInvoiceIds,
        String baseUrl,
        String realmId,
        String accessToken
    ) {
        Map<String, Map<String, Object>> byTxnId = new Map<String, Map<String, Object>>();
        if (qbInvoiceIds == null
            || qbInvoiceIds.isEmpty()
            || String.isBlank(baseUrl)
            || String.isBlank(realmId)
            || String.isBlank(accessToken)) {
            return byTxnId;
        }

        List<String> ids = new List<String>();
        for (String rawId : qbInvoiceIds) {
            if (String.isNotBlank(rawId)) {
                ids.add(rawId.trim());
            }
        }
        final Integer chunkSize = 20;
        for (Integer i = 0; i < ids.size(); i += chunkSize) {
            List<String> quoted = new List<String>();
            Integer endExclusive = Math.min(i + chunkSize, ids.size());
            for (Integer j = i; j < endExclusive; j++) {
                quoted.add('\'' + String.escapeSingleQuotes(ids[j]) + '\'');
            }
            String query =
                'select Id, Balance, TotalAmt, DueDate from Invoice where Id in ('
                + String.join(quoted, ',')
                + ')';
            String endpoint =
                baseUrl
                + '/v3/company/'
                + realmId
                + '/query?query='
                + EncodingUtil.urlEncode(query, 'UTF-8');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('GET');
            req.setHeader('Accept', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setTimeout(60000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                totalApiQueryFailures++;
                System.debug(LoggingLevel.ERROR,
                    'QuickBooksPaymentSyncBatchFixed: Invoice query failed status='
                    + res.getStatusCode());
                continue;
            }

            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> qr = root == null ? null : (Map<String, Object>) root.get('QueryResponse');
            if (qr == null || qr.get('Invoice') == null) {
                continue;
            }
            Object payload = qr.get('Invoice');
            List<Object> rows = new List<Object>();
            if (payload instanceof List<Object>) {
                rows.addAll((List<Object>) payload);
            } else if (payload instanceof Map<String, Object>) {
                rows.add(payload);
            }
            for (Object rowObj : rows) {
                if (!(rowObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> inv = (Map<String, Object>) rowObj;
                if (inv.get('Id') == null) {
                    continue;
                }
                byTxnId.put(String.valueOf(inv.get('Id')).trim(), inv);
            }
        }
        return byTxnId;
    }

    /**
     * After Payment DML: set Invoice Status to Paid, Partially Paid, or Over Due.
     * Picklist includes: Sent to Customer, Over Due, Paid, Partially Paid, etc.
     */
    @TestVisible
    private void updateInvoiceStatusesFromPayments(
        Map<Id, String> invoiceIdToQbTxnId,
        Map<String, Map<String, Object>> qbInvoicePayloadByTxnId
    ) {
        if (invoiceIdToQbTxnId == null || invoiceIdToQbTxnId.isEmpty()) {
            return;
        }

        Map<String, List<Id>> idsByObject = new Map<String, List<Id>>();
        for (Id invoiceId : invoiceIdToQbTxnId.keySet()) {
            if (invoiceId == null) {
                continue;
            }
            String objectName = invoiceId.getSObjectType().getDescribe().getName();
            if (!idsByObject.containsKey(objectName)) {
                idsByObject.put(objectName, new List<Id>());
            }
            idsByObject.get(objectName).add(invoiceId);
        }

        List<SObject> toUpdate = new List<SObject>();
        for (String objectName : idsByObject.keySet()) {
            Schema.SObjectType token = getType(objectName);
            if (token == null) {
                continue;
            }
            Map<String, Schema.SObjectField> fields = token.getDescribe().fields.getMap();
            String statusField = firstMatchingField(fields, new List<String>{
                'fax__Status__c', 'faxa__Status__c', 'Status__c'
            });
            if (String.isBlank(statusField)) {
                continue;
            }
            Schema.DescribeFieldResult statusDescribe = fields.get(statusField.toLowerCase()).getDescribe();
            if (!statusDescribe.isUpdateable()) {
                continue;
            }

            String amountDueField = firstMatchingField(fields, new List<String>{
                'fax__Amount_Due__c', 'faxa__Amount_Due__c', 'Amount_Due__c'
            });
            String amountPaidField = firstMatchingField(fields, new List<String>{
                'fax__Amount_Paid__c', 'faxa__Amount_Paid__c', 'Amount_Paid__c'
            });
            String grandTotalField = firstMatchingField(fields, new List<String>{
                'fax__Grand_Total__c', 'faxa__Grand_Total__c', 'Grand_Total__c', 'fax__Total__c'
            });
            String dueDateField = firstMatchingField(fields, new List<String>{
                'fax__Due_Date__c', 'faxa__Due_Date__c', 'Due_Date__c', 'fax__Payment_Due_Date__c'
            });

            List<String> selectFields = new List<String>{ 'Id', statusField };
            if (String.isNotBlank(amountDueField)) selectFields.add(amountDueField);
            if (String.isNotBlank(amountPaidField)) selectFields.add(amountPaidField);
            if (String.isNotBlank(grandTotalField)) selectFields.add(grandTotalField);
            if (String.isNotBlank(dueDateField)) selectFields.add(dueDateField);

            List<Id> invoiceIds = idsByObject.get(objectName);
            String soql =
                'SELECT ' + String.join(selectFields, ',')
                + ' FROM ' + token.getDescribe().getName()
                + ' WHERE Id IN :invoiceIds';
            for (SObject row : Database.query(soql)) {
                String qbTxnId = invoiceIdToQbTxnId.get(row.Id);
                Map<String, Object> qbInvoice =
                    (String.isNotBlank(qbTxnId) && qbInvoicePayloadByTxnId != null)
                        ? qbInvoicePayloadByTxnId.get(qbTxnId)
                        : null;
                String nextStatus = deriveInvoiceStatusFromPayment(
                    row,
                    qbInvoice,
                    statusField,
                    amountDueField,
                    amountPaidField,
                    grandTotalField,
                    dueDateField
                );
                if (String.isBlank(nextStatus)) {
                    continue;
                }
                Object current = row.get(statusField);
                if (current != null && nextStatus.equalsIgnoreCase(String.valueOf(current))) {
                    continue;
                }
                SObject upd = token.newSObject(row.Id);
                upd.put(statusField, nextStatus);
                toUpdate.add(upd);
            }
        }

        if (toUpdate.isEmpty()) {
            return;
        }
        Database.SaveResult[] results = Database.update(toUpdate, false);
        for (Database.SaveResult sr : results) {
            if (sr != null && sr.isSuccess()) {
                totalInvoicesStatusUpdated++;
            }
        }
    }

    @TestVisible
    private static String deriveInvoiceStatusFromPayment(
        SObject invoiceRow,
        Map<String, Object> qbInvoice,
        String statusField,
        String amountDueField,
        String amountPaidField,
        String grandTotalField,
        String dueDateField
    ) {
        Decimal balance = qbInvoice == null ? null : extractDecimal(qbInvoice.get('Balance'));
        Decimal totalAmt = qbInvoice == null ? null : extractDecimal(qbInvoice.get('TotalAmt'));
        Date qbDueDate = qbInvoice == null ? null : parseQuickBooksDate(qbInvoice.get('DueDate'));

        Decimal amountDue = (invoiceRow != null && String.isNotBlank(amountDueField))
            ? (Decimal) invoiceRow.get(amountDueField) : null;
        Decimal amountPaid = (invoiceRow != null && String.isNotBlank(amountPaidField))
            ? (Decimal) invoiceRow.get(amountPaidField) : null;
        Decimal grandTotal = (invoiceRow != null && String.isNotBlank(grandTotalField))
            ? (Decimal) invoiceRow.get(grandTotalField) : null;
        Date sfDueDate = (invoiceRow != null && String.isNotBlank(dueDateField))
            ? (Date) invoiceRow.get(dueDateField) : null;

        if (balance == null) {
            balance = amountDue;
        }
        if (totalAmt == null) {
            totalAmt = grandTotal;
        }

        Boolean hasQbBalance = qbInvoice != null && qbInvoice.get('Balance') != null;

        // Fully paid → Paid (prefer explicit QB Balance when present)
        if (balance != null && balance <= 0) {
            return 'Paid';
        }
        // SF rollup fallbacks only when QB Balance was not supplied
        if (!hasQbBalance) {
            if (amountPaid != null && grandTotal != null && grandTotal > 0 && amountPaid >= grandTotal) {
                return 'Paid';
            }
            if (amountDue != null && amountDue <= 0 && amountPaid != null && amountPaid > 0) {
                return 'Paid';
            }
        }

        Boolean stillOwes =
            (balance != null && balance > 0)
            || (amountDue != null && amountDue > 0)
            || (totalAmt != null && amountPaid != null && amountPaid < totalAmt);

        // Partial payment: some paid, still owes
        Boolean partiallyPaid =
            (balance != null && totalAmt != null && balance > 0 && balance < totalAmt)
            || (!hasQbBalance && amountPaid != null && amountPaid > 0 && amountDue != null && amountDue > 0)
            || (!hasQbBalance && amountPaid != null && amountPaid > 0 && grandTotal != null && grandTotal > 0 && amountPaid < grandTotal);

        Date effectiveDue = qbDueDate != null ? qbDueDate : sfDueDate;
        if (stillOwes && effectiveDue != null && effectiveDue < Date.today()) {
            // Past due with open balance: Over Due takes priority over Partially Paid
            return 'Over Due';
        }
        if (partiallyPaid) {
            return 'Partially Paid';
        }

        return null;
    }

    @TestVisible
    private void seedFinishStateForTest(
        Integer qbFetched,
        Integer paymentsUpserted,
        Integer trackingLogs,
        Integer apiFailures,
        Integer unchanged,
        Integer queuedUpdate,
        Integer queuedInsert,
        Integer missingInvoiceLink
    ) {
        totalQbPaymentsFetched = qbFetched == null ? 0 : qbFetched;
        totalPaymentsUpserted = paymentsUpserted == null ? 0 : paymentsUpserted;
        totalTrackingLogsWritten = trackingLogs == null ? 0 : trackingLogs;
        totalApiQueryFailures = apiFailures == null ? 0 : apiFailures;
        totalPaymentsUnchanged = unchanged == null ? 0 : unchanged;
        totalPaymentsQueuedForUpdate = queuedUpdate == null ? 0 : queuedUpdate;
        totalPaymentsQueuedForInsert = queuedInsert == null ? 0 : queuedInsert;
        totalPaymentsMissingInvoiceLink = missingInvoiceLink == null ? 0 : missingInvoiceLink;
        resolvedPaymentObjectName = 'fax__Payment__c';
    }

    @TestVisible
    private void seedBatchSkipReasonForTest(String reason) {
        batchSkipReason = reason;
    }

    public void finish(Database.BatchableContext bc) {
        String objectName = String.isNotBlank(resolvedPaymentObjectName) ? resolvedPaymentObjectName : 'Payment';
        if (String.isNotBlank(batchSkipReason)) {
            insertBatchSystemLog('QuickBooksPaymentSyncBatchFixed Error', batchSkipReason, objectName);
            return;
        }

        String message = 'QB payments fetched=' + totalQbPaymentsFetched
            + ', payments upserted=' + totalPaymentsUpserted
            + ', tracking logs=' + totalTrackingLogsWritten
            + ', api failures=' + totalApiQueryFailures
            + ', unchanged=' + totalPaymentsUnchanged
            + ', queued update=' + totalPaymentsQueuedForUpdate
            + ', queued insert=' + totalPaymentsQueuedForInsert
            + ', missing invoice link=' + totalPaymentsMissingInvoiceLink
            + ', invoices status updated=' + totalInvoicesStatusUpdated
            + ', sandbox=' + useSandbox + '.';
        insertBatchSystemLog('QuickBooksPaymentSyncBatchFixed: Finished.', message, objectName);
    }

    private void recordBatchSkipReason(String reason) {
        if (String.isBlank(batchSkipReason)) {
            batchSkipReason = reason;
        }
    }

    private faxa__External_App__c getQuickBooksApp() {
        List<faxa__External_App__c> apps = [
            SELECT Id, Name, faxa__Realm_ID__c, faxa__Access_Token__c, faxa__Authentication_Status__c
            FROM faxa__External_App__c
            WHERE Name = :APP_NAME
            LIMIT 1
        ];
        return apps.isEmpty() ? null : apps[0];
    }

    private String resolvePaymentObjectName() {
        if (String.isNotBlank(paymentObjectNameHint) && Schema.getGlobalDescribe().containsKey(paymentObjectNameHint.toLowerCase())) {
            return paymentObjectNameHint;
        }
        for (String candidate : PAYMENT_OBJECT_CANDIDATES) {
            if (Schema.getGlobalDescribe().containsKey(candidate.toLowerCase())) {
                return candidate;
            }
        }
        return null;
    }

    private List<String> resolveInvoiceObjectNames() {
        List<String> names = new List<String>();
        for (String candidate : invoiceObjectNameHints) {
            if (Schema.getGlobalDescribe().containsKey(candidate.toLowerCase())) {
                names.add(candidate);
            }
        }
        for (String candidate : INVOICE_OBJECT_CANDIDATES) {
            if (Schema.getGlobalDescribe().containsKey(candidate.toLowerCase()) && !names.contains(candidate)) {
                names.add(candidate);
            }
        }
        return names;
    }

    private PaymentObjectConfig describePaymentObject(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        Schema.SObjectType token = getType(objectName);
        if (token == null) {
            return null;
        }
        Map<String, Schema.SObjectField> fields = token.getDescribe().fields.getMap();

        PaymentObjectConfig cfg = new PaymentObjectConfig();
        cfg.objectName = token.getDescribe().getName();
        cfg.token = token;
        cfg.quickBooksPaymentIdField = firstMatchingField(fields, new List<String>{ 'QuickBooks_Payment_Id__c', 'faxa__QuickBooks_Payment_Id__c' });
        cfg.invoiceLookupField = firstMatchingField(fields, new List<String>{ 'fax__Invoice__c', 'faxa__Invoice__c', 'Invoice__c' });
        cfg.amountField = firstMatchingField(fields, new List<String>{ 'fax__Amount_Paid__c', 'faxa__Amount__c', 'Amount__c' });
        cfg.dateField = firstMatchingField(fields, new List<String>{ 'fax__Payment_Date__c', 'faxa__Date__c', 'Payment_Date__c' });
        cfg.statusField = firstMatchingField(fields, new List<String>{ 'fax__Status__c', 'faxa__Status__c', 'Status__c' });
        cfg.allowedInvoiceObjectNames = new Set<String>();
        if (String.isNotBlank(cfg.invoiceLookupField) && fields.containsKey(cfg.invoiceLookupField.toLowerCase())) {
            for (Schema.SObjectType refType : fields.get(cfg.invoiceLookupField.toLowerCase()).getDescribe().getReferenceTo()) {
                cfg.allowedInvoiceObjectNames.add(refType.getDescribe().getName());
            }
        }

        if (String.isBlank(cfg.quickBooksPaymentIdField) || String.isBlank(cfg.invoiceLookupField)) {
            return null;
        }
        return cfg;
    }

    private Map<String, SObject> loadExistingPaymentsByCompositeKey(PaymentObjectConfig cfg, Set<String> qbIds) {
        Map<String, SObject> rows = new Map<String, SObject>();
        if (cfg == null || qbIds == null || qbIds.isEmpty()) {
            return rows;
        }

        List<String> selectFields = new List<String>{ 'Id', cfg.quickBooksPaymentIdField, cfg.invoiceLookupField };
        if (String.isNotBlank(cfg.amountField)) selectFields.add(cfg.amountField);
        if (String.isNotBlank(cfg.dateField)) selectFields.add(cfg.dateField);
        if (String.isNotBlank(cfg.statusField)) selectFields.add(cfg.statusField);

        for (SObject row : Database.query(
            'SELECT ' + String.join(selectFields, ', ') +
            ' FROM ' + cfg.objectName +
            ' WHERE ' + cfg.quickBooksPaymentIdField + ' IN :qbIds'
        )) {
            Object qbId = row.get(cfg.quickBooksPaymentIdField);
            Object invoiceId = row.get(cfg.invoiceLookupField);
            if (qbId == null || invoiceId == null) {
                continue;
            }
            String key = buildPaymentCompositeKey(String.valueOf(qbId).trim(), (Id) invoiceId);
            // First row wins if duplicates already exist.
            if (!rows.containsKey(key)) {
                rows.put(key, row);
            }
        }
        return rows;
    }

    @TestVisible
    private static String buildPaymentCompositeKey(String qbPaymentId, Id invoiceId) {
        return (qbPaymentId == null ? '' : qbPaymentId.trim()) + '|' + String.valueOf(invoiceId);
    }

    private Map<String, InvoiceMatch> loadInvoicesByQuickBooksId(Set<String> qbInvoiceIds, PaymentObjectConfig paymentConfig) {
        Map<String, InvoiceMatch> matches = new Map<String, InvoiceMatch>();
        if (qbInvoiceIds == null || qbInvoiceIds.isEmpty()) {
            return matches;
        }

        for (String objectName : resolvedInvoiceObjectNames) {
            Schema.SObjectType token = getType(objectName);
            if (token == null) {
                continue;
            }
            String resolvedName = token.getDescribe().getName();
            // Only use Invoice objects that the Payment lookup can reference.
            if (paymentConfig != null
                && paymentConfig.allowedInvoiceObjectNames != null
                && !paymentConfig.allowedInvoiceObjectNames.isEmpty()
                && !paymentConfig.allowedInvoiceObjectNames.contains(resolvedName)) {
                continue;
            }
            Map<String, Schema.SObjectField> fields = token.getDescribe().fields.getMap();
            String qbInvoiceField = findQuickBooksInvoiceIdField(fields);
            if (String.isBlank(qbInvoiceField)) {
                continue;
            }

            for (SObject row : Database.query(
                'SELECT Id, ' + qbInvoiceField + ' FROM ' + resolvedName +
                ' WHERE ' + qbInvoiceField + ' IN :qbInvoiceIds'
            )) {
                Object value = row.get(qbInvoiceField);
                if (value == null) {
                    continue;
                }
                String key = String.valueOf(value).trim();
                if (!matches.containsKey(key)) {
                    matches.put(key, new InvoiceMatch(row.Id, row.getSObjectType().getDescribe().getName()));
                }
            }
        }
        return matches;
    }

    private String findQuickBooksInvoiceIdField(Map<String, Schema.SObjectField> fields) {
        for (String fieldName : fields.keySet()) {
            String lower = fieldName.toLowerCase();
            Schema.DescribeFieldResult d = fields.get(fieldName).getDescribe();
            if ((d.getType() == Schema.DisplayType.STRING || d.getType() == Schema.DisplayType.TEXTAREA)
                && lower.contains('quickbooks')
                && lower.contains('invoice')
                && !lower.contains('__r')) {
                return d.getName();
            }
        }
        return null;
    }

    private SObject buildPaymentRecord(
        PaymentObjectConfig cfg,
        Map<String, Object> qbPayment,
        String qbPaymentId,
        String qbInvoiceId,
        Decimal appliedAmount,
        InvoiceMatch invoiceMatch,
        SObject existingPayment
    ) {
        if (cfg == null || invoiceMatch == null || invoiceMatch.invoiceId == null) {
            return null;
        }
        // Guard: Payment.Invoice lookup must accept this Invoice sObject type.
        if (cfg.allowedInvoiceObjectNames != null
            && !cfg.allowedInvoiceObjectNames.isEmpty()
            && !cfg.allowedInvoiceObjectNames.contains(invoiceMatch.objectName)) {
            return null;
        }

        SObject record = cfg.token.newSObject();
        // Same QB Payment Id is stored on each SF Payment split row (one per Invoice application).
        record.put(cfg.quickBooksPaymentIdField, qbPaymentId);

        // Invoice lookup is often create-only (e.g. fax__Invoice__c on fax__Payment__c).
        Map<String, Schema.SObjectField> fields = cfg.token.getDescribe().fields.getMap();
        Schema.DescribeFieldResult invoiceFieldDescribe = fields.get(cfg.invoiceLookupField.toLowerCase()).getDescribe();
        Boolean canWriteInvoice =
            (existingPayment == null && invoiceFieldDescribe.isCreateable())
            || (existingPayment != null && invoiceFieldDescribe.isUpdateable());
        if (canWriteInvoice) {
            record.put(cfg.invoiceLookupField, invoiceMatch.invoiceId);
        } else if (existingPayment == null) {
            // Required invoice lookup cannot be written — skip create.
            return null;
        }

        if (String.isNotBlank(cfg.amountField)) {
            Decimal amount = appliedAmount;
            if (amount == null) {
                amount = extractQuickBooksPaymentAmountForInvoice(qbPayment, qbInvoiceId);
            }
            if (amount != null) {
                record.put(cfg.amountField, amount);
            }
        }
        if (String.isNotBlank(cfg.dateField)) {
            Date txnDate = parseQuickBooksDate(qbPayment.get('TxnDate'));
            if (txnDate != null) {
                record.put(cfg.dateField, txnDate);
            }
        }
        if (String.isNotBlank(cfg.statusField)) {
            record.put(cfg.statusField, 'Paid');
        }
        if (existingPayment != null) {
            record.put('Id', existingPayment.Id);
        }
        return record;
    }

    private Boolean hasChanges(PaymentObjectConfig cfg, SObject candidate, SObject existing) {
        if (candidate == null || existing == null) {
            return true;
        }
        for (String fieldName : candidate.getPopulatedFieldsAsMap().keySet()) {
            if ('Id'.equalsIgnoreCase(fieldName)) {
                continue;
            }
            if (!areValuesEqual(candidate.get(fieldName), existing.get(fieldName))) {
                return true;
            }
        }
        return false;
    }

    private void recordResults(
        Database.SaveResult[] results,
        List<SObject> records,
        Id appId,
        String paymentObjectName,
        List<PaymentSyncTrackingRequest> tracking,
        Boolean isUpdate
    ) {
        for (Integer i = 0; i < results.size(); i++) {
            SObject row = records[i];
            if (results[i].isSuccess()) {
                totalPaymentsUpserted++;
                tracking.add(new PaymentSyncTrackingRequest(
                    appId,
                    null,
                    paymentObjectName,
                    isUpdate ? 'QuickBooks Payment updated successfully.' : 'QuickBooks Payment created successfully.',
                    true
                ));
            } else {
                String errorMessage = results[i].getErrors().isEmpty()
                    ? 'Unknown DML error'
                    : results[i].getErrors()[0].getMessage();
                tracking.add(new PaymentSyncTrackingRequest(appId, null, paymentObjectName, errorMessage, false));
            }
        }
    }

    private void insertBatchSystemLog(String status, String message, String objectName) {
        try {
            insert new faxa__External_App_Request_Log__c(
                faxa__Status__c = status,
                faxa__Object_Name__c = objectName,
                faxa__Error_Message__c = abbreviate(message, 32768)
            );
            totalTrackingLogsWritten++;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'QuickBooksPaymentSyncBatchFixed log insert failed: ' + e.getMessage());
        }
    }

    @TestVisible
    private void runFlushForTest(
        Id appId,
        Id parentId,
        String parentObjectName,
        String paymentObjectName,
        String message,
        Boolean success
    ) {
        flushPaymentSyncTracking(new List<PaymentSyncTrackingRequest>{
            new PaymentSyncTrackingRequest(appId, parentId, parentObjectName, message, success)
        });
    }

    private void flushPaymentSyncTracking(List<PaymentSyncTrackingRequest> trackingQueue) {
        if (trackingQueue == null || trackingQueue.isEmpty()) {
            return;
        }

        List<faxa__External_App_Request__c> requests = new List<faxa__External_App_Request__c>();
        List<faxa__External_App_Request_Log__c> logs = new List<faxa__External_App_Request_Log__c>();
        for (PaymentSyncTrackingRequest item : trackingQueue) {
            if (item == null || item.appId == null) {
                continue;
            }
            faxa__External_App_Request__c req = new faxa__External_App_Request__c(
                faxa__External_App__c = item.appId,
                faxa__Object_Name__c = item.parentObjectName,
                faxa__Parent_ID__c = item.parentId == null ? null : String.valueOf(item.parentId),
                faxa__Request_Body__c = item.message,
                faxa__Response__c = item.success ? 'Success' : 'Failed'
            );
            requests.add(req);
        }
        if (!requests.isEmpty()) {
            Database.SaveResult[] requestResults = Database.insert(requests, false);
            for (Integer i = 0; i < requestResults.size(); i++) {
                String status = (trackingQueue[i] != null && trackingQueue[i].success) ? 'Success' : 'Failed';
                String error = requestResults[i].isSuccess()
                    ? null
                    : (requestResults[i].getErrors().isEmpty() ? 'Unknown DML error' : requestResults[i].getErrors()[0].getMessage());
                logs.add(new faxa__External_App_Request_Log__c(
                    faxa__Status__c = status,
                    faxa__Object_Name__c = trackingQueue[i].parentObjectName,
                    faxa__QB_Http_Request__c = requestResults[i].isSuccess() ? requestResults[i].getId() : null,
                    faxa__Error_Message__c = requestResults[i].isSuccess() ? abbreviate(trackingQueue[i].message, 32768) : abbreviate(error, 32768)
                ));
            }
        }
        if (!logs.isEmpty()) {
            insert logs;
            totalTrackingLogsWritten += logs.size();
        }
    }

    @TestVisible
    private void runLogBulkFailuresForTest(String payObj) {
        insertBatchSystemLog('QuickBooksPaymentSyncBatchFixed Error', 'Synthetic failure', payObj);
    }

    /**
     * One QB Payment may apply to many Invoices via Line/LinkedTxn.
     * Returns one application per QB Invoice Id (amounts summed when the same invoice appears on multiple lines).
     */
    @TestVisible
    private static List<PaymentInvoiceApplication> extractInvoiceApplicationsFromPayment(Map<String, Object> qbPayment) {
        Map<String, Decimal> amountByInvoiceId = new Map<String, Decimal>();
        for (Object lineObj : asObjectList(qbPayment == null ? null : qbPayment.get('Line'))) {
            if (!(lineObj instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> line = (Map<String, Object>) lineObj;
            Decimal lineAmount = extractDecimal(line.get('Amount'));
            Set<String> invoiceIdsOnLine = new Set<String>();
            for (Object txObj : asObjectList(line.get('LinkedTxn'))) {
                if (!(txObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> tx = (Map<String, Object>) txObj;
                if ('Invoice'.equalsIgnoreCase(String.valueOf(tx.get('TxnType'))) && tx.get('TxnId') != null) {
                    invoiceIdsOnLine.add(String.valueOf(tx.get('TxnId')).trim());
                }
            }
            for (String qbInvoiceId : invoiceIdsOnLine) {
                if (String.isBlank(qbInvoiceId)) {
                    continue;
                }
                Decimal current = amountByInvoiceId.containsKey(qbInvoiceId) ? amountByInvoiceId.get(qbInvoiceId) : 0;
                amountByInvoiceId.put(qbInvoiceId, current + (lineAmount == null ? 0 : lineAmount));
            }
        }

        List<PaymentInvoiceApplication> applications = new List<PaymentInvoiceApplication>();
        for (String qbInvoiceId : amountByInvoiceId.keySet()) {
            applications.add(new PaymentInvoiceApplication(qbInvoiceId, amountByInvoiceId.get(qbInvoiceId)));
        }
        return applications;
    }

    private static String extractQbInvoiceIdFromPayment(Map<String, Object> qbPayment) {
        List<PaymentInvoiceApplication> applications = extractInvoiceApplicationsFromPayment(qbPayment);
        return applications.isEmpty() ? null : applications[0].qbInvoiceId;
    }

    private static Decimal extractQuickBooksPaymentAmountForInvoice(Map<String, Object> qbPayment, String qbInvoiceId) {
        Decimal lineAmount = extractLinePaymentAmountForInvoice(qbPayment, qbInvoiceId);
        if (lineAmount != null) {
            return lineAmount;
        }
        return extractDecimal(qbPayment == null ? null : qbPayment.get('TotalAmt'));
    }

    private static Decimal extractLinePaymentAmountForInvoice(Map<String, Object> qbPayment, String qbInvoiceId) {
        Object linesObj = qbPayment == null ? null : qbPayment.get('Line');
        List<Object> lines = asObjectList(linesObj);
        if (lines.isEmpty()) {
            return null;
        }
        Decimal total = 0;
        Boolean found = false;
        for (Object lineObj : lines) {
            if (!(lineObj instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> line = (Map<String, Object>) lineObj;
            if (String.isNotBlank(qbInvoiceId) && !lineReferencesInvoice(line, qbInvoiceId)) {
                continue;
            }
            Decimal amount = extractDecimal(line.get('Amount'));
            if (amount != null) {
                total += amount;
                found = true;
            }
        }
        return found ? total : null;
    }

    private static Boolean lineReferencesInvoice(Map<String, Object> line, String qbInvoiceId) {
        for (Object txObj : asObjectList(line == null ? null : line.get('LinkedTxn'))) {
            if (!(txObj instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> tx = (Map<String, Object>) txObj;
            if ('Invoice'.equalsIgnoreCase(String.valueOf(tx.get('TxnType')))
                && qbInvoiceId == String.valueOf(tx.get('TxnId')).trim()) {
                return true;
            }
        }
        return false;
    }

    /** QB JSON may return a single object or an array for Line / LinkedTxn. */
    @TestVisible
    private static List<Object> asObjectList(Object raw) {
        List<Object> rows = new List<Object>();
        if (raw == null) {
            return rows;
        }
        if (raw instanceof List<Object>) {
            rows.addAll((List<Object>) raw);
        } else {
            rows.add(raw);
        }
        return rows;
    }

    private static Decimal extractDecimal(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    private static Date parseQuickBooksDate(Object value) {
        if (value == null) return null;
        try {
            String raw = String.valueOf(value).trim();
            return raw.length() >= 10 ? Date.valueOf(raw.substring(0, 10)) : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean areValuesEqual(Object left, Object right) {
        if (left == null && right == null) return true;
        if (left == null || right == null) return false;
        return String.valueOf(left) == String.valueOf(right);
    }

    private static String abbreviate(String value, Integer maxLength) {
        if (value == null) return null;
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }

    private static Schema.SObjectType getType(String objectName) {
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType token = gd.get(objectName);
        if (token == null) {
            token = gd.get(objectName.toLowerCase());
        }
        return token;
    }

    private static String firstMatchingField(Map<String, Schema.SObjectField> fields, List<String> candidates) {
        for (String candidate : candidates) {
            for (String fieldName : fields.keySet()) {
                if (fieldName != null && fieldName.equalsIgnoreCase(candidate)) {
                    return fields.get(fieldName).getDescribe().getName();
                }
            }
        }
        return null;
    }

    public static Id runBatch() {
        // Airquip UAT uses FieldAx core Payment/Invoice (fax__).
        return Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed('fax__Payment__c', new List<String>{ 'fax__Invoice__c' }),
            RECOMMENDED_BATCH_SIZE
        );
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(
            new QuickBooksPaymentSyncBatchFixed(
                String.isNotBlank(paymentObjectNameHint) ? paymentObjectNameHint : 'fax__Payment__c',
                (invoiceObjectNameHints != null && !invoiceObjectNameHints.isEmpty())
                    ? invoiceObjectNameHints
                    : new List<String>{ 'fax__Invoice__c' },
                useSandbox
            ),
            RECOMMENDED_BATCH_SIZE
        );
    }

    private class PaymentObjectConfig {
        String objectName;
        Schema.SObjectType token;
        String quickBooksPaymentIdField;
        String invoiceLookupField;
        String amountField;
        String dateField;
        String statusField;
        Set<String> allowedInvoiceObjectNames;
    }

    private class InvoiceMatch {
        Id invoiceId;
        String objectName;
        InvoiceMatch(Id invoiceId, String objectName) {
            this.invoiceId = invoiceId;
            this.objectName = objectName;
        }
    }

    @TestVisible
    private class PaymentInvoiceApplication {
        @TestVisible String qbInvoiceId;
        @TestVisible Decimal amount;
        PaymentInvoiceApplication(String qbInvoiceId, Decimal amount) {
            this.qbInvoiceId = qbInvoiceId;
            this.amount = amount;
        }
    }

    private class PaymentSyncTrackingRequest {
        Id appId;
        Id parentId;
        String parentObjectName;
        String message;
        Boolean success;
        PaymentSyncTrackingRequest(Id appId, Id parentId, String parentObjectName, String message, Boolean success) {
            this.appId = appId;
            this.parentId = parentId;
            this.parentObjectName = parentObjectName;
            this.message = message;
            this.success = success;
        }
    }

    public class QuickBooksPaymentSyncBatchFixedException extends Exception {}
}