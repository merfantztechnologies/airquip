public with sharing class KnowledgeSuggestionController {
    private static final Integer MAX_SEARCH_TERMS = 10;
    private static final Integer MAX_SUGGESTED_RESULTS = 20;
    private static final Integer MAX_ATTACHED_RESULTS = 50;
    private static final Integer MAX_ATTACHED_LINKS = 200;
    private static final Integer MAX_FALLBACK_RESULTS = 10;
    private static final Integer MAX_NAME_LENGTH = 80;
    private static final Integer MAX_URL_NAME_LENGTH = 255;
    private static final Integer MAX_ARTICLE_BODY_LENGTH = 131072;
    private static final Set<String> ALLOWED_STATUS_VALUES = new Set<String>{
        'Draft',
        'Review',
        'Published',
        'Archived'
    };

    public class ArticleSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String urlName;
        @AuraEnabled public String excerpt;
        @AuraEnabled public Boolean isAttached;
    }

    public class KnowledgeResponse {
        @AuraEnabled public String searchText;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public List<ArticleSummary> articles;
    }

    public class ArticlePreview {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String urlName;
        @AuraEnabled public String status;
        @AuraEnabled public String lastModifiedDate;
        @AuraEnabled public String articleNumber;
        @AuraEnabled public String articleBody;
    }

    @TestVisible
    private static Map<String, Knowledge_Search_Config__mdt> activeConfigByObject;

    @TestVisible
    private static Map<String, Map<String, Schema.SObjectField>> fieldMapCacheByObject;

    @AuraEnabled
    public static KnowledgeResponse getKnowledgeForRecord(
        Id recordId,
        String searchFieldOverride,
        String descriptionFieldOverride
    ) {
        try {
            return getKnowledgeForRecordInternal(
                recordId,
                searchFieldOverride,
                descriptionFieldOverride
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw buildHandledException(ex);
        }
    }

    @AuraEnabled
    public static ArticlePreview getArticlePreview(Id articleId) {
        try {
            if (articleId == null) {
                throw new AuraHandledException('Article Id is required.');
            }

            List<Knowledge_Article__c> articles = [
                SELECT Id, Name, Url_Name__c, Status__c, Article_Body__c, LastModifiedDate
                FROM Knowledge_Article__c
                WHERE Id = :articleId
                WITH USER_MODE
                LIMIT 1
            ];

            if (articles.isEmpty()) {
                throw new AuraHandledException('Article not found or you do not have access.');
            }

            Knowledge_Article__c article = articles[0];
            ArticlePreview preview = new ArticlePreview();
            preview.id = article.Id;
            preview.title = article.Name;
            preview.urlName = article.Url_Name__c;
            preview.status = article.Status__c;
            preview.lastModifiedDate = article.LastModifiedDate != null
                ? article.LastModifiedDate.format('MM/dd/yyyy, h:mm a')
                : '';
            preview.articleNumber = String.valueOf(article.Id).right(9);
            preview.articleBody = article.Article_Body__c;
            return preview;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw buildHandledException(ex);
        }
    }

    @AuraEnabled
    public static Id createArticle(
        String name,
        String urlName,
        String articleBody,
        String status,
        Boolean isVisibleInApp
    ) {
        try {
            assertCreateAccess();

            if (String.isBlank(name)) {
                throw new AuraHandledException('Article Title is required.');
            }

            String trimmedName = truncate(name.trim(), MAX_NAME_LENGTH);

            String resolvedUrlName = String.isNotBlank(urlName)
                ? truncate(urlName.trim(), MAX_URL_NAME_LENGTH)
                : buildUrlName(trimmedName);
            if (String.isBlank(resolvedUrlName)) {
                throw new AuraHandledException('URL Name is required.');
            }

            String resolvedStatus = String.isNotBlank(status) ? status.trim() : 'Draft';
            if (!ALLOWED_STATUS_VALUES.contains(resolvedStatus)) {
                throw new AuraHandledException('Invalid status value.');
            }

            String resolvedBody = articleBody;
            if (resolvedBody != null && resolvedBody.length() > MAX_ARTICLE_BODY_LENGTH) {
                resolvedBody = resolvedBody.substring(0, MAX_ARTICLE_BODY_LENGTH);
            }

            Knowledge_Article__c article = new Knowledge_Article__c(
                Name = trimmedName,
                Url_Name__c = resolvedUrlName,
                Article_Body__c = resolvedBody,
                Status__c = resolvedStatus,
                Is_Visible_In_App__c = isVisibleInApp == true
            );

            insert as user article;
            return article.Id;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (DmlException ex) {
            throw buildDmlException(ex);
        } catch (Exception ex) {
            throw buildHandledException(ex);
        }
    }

    @AuraEnabled
    public static void attachArticle(Id recordId, Id articleId) {
        try {
            if (recordId == null || articleId == null) {
                throw new AuraHandledException('Record and article are required.');
            }

            assertArticleLinkCreateAccess();

            List<Knowledge_Article__c> articles = [
                SELECT Id
                FROM Knowledge_Article__c
                WHERE Id = :articleId
                WITH USER_MODE
                LIMIT 1
            ];
            if (articles.isEmpty()) {
                throw new AuraHandledException('Article not found or you do not have access.');
            }

            String recordIdText = String.valueOf(recordId);
            String objectApiName = recordId.getSobjectType().getDescribe().getName();

            List<Knowledge_Article_Link__c> existingLinks = [
                SELECT Id
                FROM Knowledge_Article_Link__c
                WHERE Knowledge_Article__c = :articleId
                AND Related_Record_Id__c = :recordIdText
                WITH USER_MODE
                LIMIT 1
            ];

            if (!existingLinks.isEmpty()) {
                return;
            }

            insert as user new Knowledge_Article_Link__c(
                Knowledge_Article__c = articleId,
                Related_Record_Id__c = recordIdText,
                Related_Object__c = objectApiName
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (DmlException ex) {
            throw buildDmlException(ex);
        } catch (Exception ex) {
            throw buildHandledException(ex);
        }
    }

    private static KnowledgeResponse getKnowledgeForRecordInternal(
        Id recordId,
        String searchFieldOverride,
        String descriptionFieldOverride
    ) {
        KnowledgeResponse response = new KnowledgeResponse();
        response.articles = new List<ArticleSummary>();

        if (recordId == null) {
            return response;
        }

        RecordContext context = loadRecordContext(
            recordId,
            searchFieldOverride,
            descriptionFieldOverride
        );
        response.searchText = context.searchText;
        response.objectLabel = context.objectLabel;

        Set<Id> attachedIds = getAttachedArticleIds(recordId);
        List<ArticleSummary> results = new List<ArticleSummary>();
        Set<Id> seenIds = new Set<Id>();

        for (Knowledge_Article__c article : queryAttachedArticles(attachedIds)) {
            results.add(toSummary(article, true));
            seenIds.add(article.Id);
        }

        for (Knowledge_Article__c article : querySuggestedArticles(context, attachedIds)) {
            if (seenIds.contains(article.Id)) {
                continue;
            }
            results.add(toSummary(article, false));
            seenIds.add(article.Id);
        }

        response.articles = results;
        return response;
    }

    private class RecordContext {
        public String searchText;
        public String descriptionText;
        public String objectLabel;
        public String objectApiName;
        public Id recordId;
    }

    private static RecordContext loadRecordContext(
        Id recordId,
        String searchFieldOverride,
        String descriptionFieldOverride
    ) {
        String objectApiName = recordId.getSobjectType().getDescribe().getName();
        String subjectField = resolveSubjectField(
            objectApiName,
            searchFieldOverride
        );
        String descriptionField = resolveDescriptionField(
            objectApiName,
            descriptionFieldOverride
        );

        List<String> fields = new List<String>{ 'Id', subjectField };
        if (descriptionField != null) {
            fields.add(descriptionField);
        }

        String query =
            'SELECT ' + String.join(fields, ', ') +
            ' FROM ' + String.escapeSingleQuotes(objectApiName) +
            ' WHERE Id = :recordId LIMIT 1';

        List<SObject> records = Database.queryWithBinds(
            query,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );

        if (records.isEmpty()) {
            throw new AuraHandledException('Record not found or you do not have access.');
        }

        SObject record = records[0];
        RecordContext context = new RecordContext();
        context.recordId = recordId;
        context.objectApiName = objectApiName;
        context.objectLabel = recordId.getSobjectType().getDescribe().getLabel();
        context.searchText = (String) record.get(subjectField);
        context.descriptionText = descriptionField == null
            ? null
            : (String) record.get(descriptionField);
        return context;
    }

    private static Map<String, Knowledge_Search_Config__mdt> getActiveConfigByObject() {
        if (activeConfigByObject == null) {
            activeConfigByObject = new Map<String, Knowledge_Search_Config__mdt>();
            for (Knowledge_Search_Config__mdt config : [
                SELECT Object_API_Name__c,
                    Search_Field_API_Name__c,
                    Description_Field_API_Name__c
                FROM Knowledge_Search_Config__mdt
                WHERE Is_Active__c = TRUE
                LIMIT 200
            ]) {
                activeConfigByObject.put(config.Object_API_Name__c, config);
            }
        }
        return activeConfigByObject;
    }

    private static String resolveSubjectField(
        String objectApiName,
        String searchFieldOverride
    ) {
        if (String.isNotBlank(searchFieldOverride)) {
            String fieldApiName = searchFieldOverride.trim();
            assertValidFieldApiName(fieldApiName);
            assertFieldExists(objectApiName, fieldApiName);
            return fieldApiName;
        }

        Knowledge_Search_Config__mdt config = getActiveConfigByObject().get(objectApiName);
        if (config != null && String.isNotBlank(config.Search_Field_API_Name__c)) {
            assertFieldExists(objectApiName, config.Search_Field_API_Name__c);
            return config.Search_Field_API_Name__c;
        }

        Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectApiName);

        if (fieldMap.containsKey('Subject')) {
            return 'Subject';
        }
        if (fieldMap.containsKey('Name')) {
            return 'Name';
        }

        throw new AuraHandledException(
            'Add a Knowledge Search Config record for ' +
            getObjectLabel(objectApiName) +
            ' in Setup, or set the Search Field on the component in App Builder.'
        );
    }

    private static String resolveDescriptionField(
        String objectApiName,
        String descriptionFieldOverride
    ) {
        if (String.isNotBlank(descriptionFieldOverride)) {
            String fieldApiName = descriptionFieldOverride.trim();
            assertValidFieldApiName(fieldApiName);
            assertFieldExists(objectApiName, fieldApiName);
            return fieldApiName;
        }

        Knowledge_Search_Config__mdt config = getActiveConfigByObject().get(objectApiName);
        if (config == null || String.isBlank(config.Description_Field_API_Name__c)) {
            return null;
        }

        Map<String, Schema.SObjectField> fieldMap = getFieldMap(objectApiName);
        String fieldApiName = config.Description_Field_API_Name__c;

        return fieldMap.containsKey(fieldApiName) ? fieldApiName : null;
    }

    private static Map<String, Schema.SObjectField> getFieldMap(String objectApiName) {
        if (fieldMapCacheByObject == null) {
            fieldMapCacheByObject = new Map<String, Map<String, Schema.SObjectField>>();
        }

        if (!fieldMapCacheByObject.containsKey(objectApiName)) {
            Schema.SObjectType objectToken = Schema.getGlobalDescribe().get(objectApiName);
            if (objectToken == null) {
                throw new AuraHandledException('Unsupported object: ' + objectApiName);
            }
            fieldMapCacheByObject.put(
                objectApiName,
                objectToken.getDescribe().fields.getMap()
            );
        }

        return fieldMapCacheByObject.get(objectApiName);
    }

    private static String getObjectLabel(String objectApiName) {
        Schema.SObjectType objectToken = Schema.getGlobalDescribe().get(objectApiName);
        return objectToken == null ? objectApiName : objectToken.getDescribe().getLabel();
    }

    private static void assertValidFieldApiName(String fieldApiName) {
        if (!Pattern.matches('^[a-zA-Z][a-zA-Z0-9_]*$', fieldApiName)) {
            throw new AuraHandledException('Invalid field API name.');
        }
    }

    private static void assertFieldExists(String objectApiName, String fieldApiName) {
        assertValidFieldApiName(fieldApiName);

        if (!getFieldMap(objectApiName).containsKey(fieldApiName)) {
            throw new AuraHandledException(
                'Field ' + fieldApiName + ' does not exist on ' + objectApiName + '.'
            );
        }
    }

    private static void assertCreateAccess() {
        if (!Schema.sObjectType.Knowledge_Article__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to create knowledge articles.');
        }
    }

    private static void assertArticleLinkCreateAccess() {
        if (!Schema.sObjectType.Knowledge_Article_Link__c.isCreateable()) {
            throw new AuraHandledException('You do not have permission to attach knowledge articles.');
        }
    }

    private static Set<Id> getAttachedArticleIds(Id recordId) {
        Set<Id> attachedIds = new Set<Id>();
        String recordIdText = String.valueOf(recordId);

        for (Knowledge_Article_Link__c link : [
            SELECT Knowledge_Article__c
            FROM Knowledge_Article_Link__c
            WHERE Related_Record_Id__c = :recordIdText
            WITH USER_MODE
            LIMIT :MAX_ATTACHED_LINKS
        ]) {
            attachedIds.add(link.Knowledge_Article__c);
        }

        return attachedIds;
    }

    private static List<Knowledge_Article__c> queryAttachedArticles(Set<Id> attachedIds) {
        if (attachedIds.isEmpty()) {
            return new List<Knowledge_Article__c>();
        }

        return [
            SELECT Id, Name, Url_Name__c, Article_Body__c, Status__c
            FROM Knowledge_Article__c
            WHERE Id IN :attachedIds
            AND Status__c = 'Published'
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_ATTACHED_RESULTS
        ];
    }

    private static List<Knowledge_Article__c> querySuggestedArticles(
        RecordContext context,
        Set<Id> attachedIds
    ) {
        List<String> subjectTerms = buildSearchTerms(context.searchText, null);

        if (!subjectTerms.isEmpty()) {
            List<Knowledge_Article__c> subjectMatches = queryArticlesByTerms(
                subjectTerms,
                attachedIds,
                MAX_SUGGESTED_RESULTS
            );
            if (!subjectMatches.isEmpty()) {
                return subjectMatches;
            }
            return new List<Knowledge_Article__c>();
        }

        List<String> descriptionTerms = buildSearchTerms(null, context.descriptionText);
        if (!descriptionTerms.isEmpty()) {
            return queryArticlesByTerms(descriptionTerms, attachedIds, MAX_SUGGESTED_RESULTS);
        }

        return [
            SELECT Id, Name, Url_Name__c, Article_Body__c, Status__c
            FROM Knowledge_Article__c
            WHERE Status__c = 'Published'
            AND Is_Visible_In_App__c = TRUE
            AND Id NOT IN :attachedIds
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_FALLBACK_RESULTS
        ];
    }

    private static List<Knowledge_Article__c> queryArticlesByTerms(
        List<String> terms,
        Set<Id> attachedIds,
        Integer resultLimit
    ) {
        if (terms == null || terms.isEmpty()) {
            return new List<Knowledge_Article__c>();
        }

        List<String> conditions = new List<String>();
        Map<String, Object> bindVars = new Map<String, Object>();
        Integer index = 0;

        for (String term : terms) {
            if (index >= MAX_SEARCH_TERMS) {
                break;
            }

            String escapedTerm = sanitizeLikeTerm(term);
            if (String.isBlank(escapedTerm)) {
                continue;
            }

            String bindName = 'term' + index;
            bindVars.put(bindName, '%' + escapedTerm + '%');
            conditions.add(
                '(Name LIKE :' + bindName +
                ' OR Url_Name__c LIKE :' + bindName + ')'
            );
            index++;
        }

        if (conditions.isEmpty()) {
            return new List<Knowledge_Article__c>();
        }

        String attachedFilter = attachedIds.isEmpty()
            ? ''
            : 'AND Id NOT IN :attachedIds ';

        if (!attachedIds.isEmpty()) {
            bindVars.put('attachedIds', attachedIds);
        }

        Integer safeLimit = resultLimit == null || resultLimit < 1
            ? MAX_SUGGESTED_RESULTS
            : Math.min(resultLimit, MAX_SUGGESTED_RESULTS);

        String query =
            'SELECT Id, Name, Url_Name__c, Article_Body__c, Status__c ' +
            'FROM Knowledge_Article__c ' +
            'WHERE Status__c = \'Published\' ' +
            'AND Is_Visible_In_App__c = TRUE ' +
            attachedFilter +
            'AND (' + String.join(conditions, ' OR ') + ') ' +
            'ORDER BY Name ' +
            'LIMIT ' + safeLimit;

        return Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
    }

    private static List<String> buildSearchTerms(String subject, String description) {
        Set<String> terms = new Set<String>();
        addTerms(terms, subject);
        if (description != null) {
            addTerms(terms, description);
        }
        return new List<String>(terms);
    }

    private static void addTerms(Set<String> terms, String value) {
        if (String.isBlank(value)) {
            return;
        }

        String normalized = value.trim();
        if (normalized.length() >= 3 && terms.size() < MAX_SEARCH_TERMS) {
            terms.add(normalized);
        }

        for (String token : normalized.split('[\\s,;/\\\\|]+')) {
            if (terms.size() >= MAX_SEARCH_TERMS) {
                break;
            }

            String cleaned = token.trim();
            if (cleaned.length() >= 3) {
                terms.add(cleaned);
            }
        }
    }

    @TestVisible
    private static String sanitizeLikeTerm(String value) {
        if (String.isBlank(value)) {
            return '';
        }

        String sanitized = value
            .replace('\\', ' ')
            .replace('%', ' ')
            .replace('_', ' ')
            .replaceAll('\\s+', ' ')
            .trim();

        return sanitized.length() >= 3 ? sanitized : '';
    }

    @TestVisible
    private static void resetCaches() {
        activeConfigByObject = null;
        fieldMapCacheByObject = null;
    }

    private static ArticleSummary toSummary(Knowledge_Article__c article, Boolean isAttached) {
        ArticleSummary summary = new ArticleSummary();
        summary.id = article.Id;
        summary.title = article.Name;
        summary.urlName = article.Url_Name__c;
        summary.excerpt = buildExcerpt(article.Article_Body__c);
        summary.isAttached = isAttached;
        return summary;
    }

    private static String buildExcerpt(String body) {
        if (String.isBlank(body)) {
            return '';
        }

        String plainText = body.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
        if (plainText.length() <= 180) {
            return plainText;
        }
        return plainText.substring(0, 177) + '...';
    }

    @TestVisible
    private static String buildUrlName(String title) {
        if (String.isBlank(title)) {
            return '';
        }

        String slug = title.toLowerCase().replaceAll('[^a-z0-9]+', '-').replaceAll('^-+|-+$', '');
        if (slug.length() > MAX_NAME_LENGTH) {
            slug = slug.substring(0, MAX_NAME_LENGTH).replaceAll('-+$', '');
        }
        return slug;
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }

    private static AuraHandledException buildHandledException(Exception ex) {
        return new AuraHandledException(
            String.isNotBlank(ex.getMessage())
                ? ex.getMessage()
                : 'An unexpected error occurred while processing knowledge articles.'
        );
    }

    private static AuraHandledException buildDmlException(DmlException ex) {
        if (ex.getNumDml() > 0) {
            System.StatusCode dmlStatus = ex.getDmlType(0);
            if (dmlStatus == System.StatusCode.DUPLICATE_VALUE) {
                return new AuraHandledException(
                    'An article with this URL Name already exists. Choose a different URL Name.'
                );
            }
            if (dmlStatus == System.StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION ||
                dmlStatus == System.StatusCode.INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST) {
                return new AuraHandledException(ex.getDmlMessage(0));
            }
            if (dmlStatus == System.StatusCode.INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY ||
                dmlStatus == System.StatusCode.INSUFFICIENT_ACCESS_OR_READONLY) {
                return new AuraHandledException('You do not have permission to complete this action.');
            }
        }

        return buildHandledException(ex);
    }
}