@IsTest
private class KnowledgeSuggestionControllerTest {
    @TestSetup
    static void setupKnowledgeAccess() {
        KnowledgeSuggestionController.resetCaches();
        assignKnowledgeArticleAccess();
    }

    private static void assignKnowledgeArticleAccess() {
        List<PermissionSet> permissionSets = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'Knowledge_Article_Access'
            LIMIT 1
        ];
        if (permissionSets.isEmpty()) {
            return;
        }

        Id userId = UserInfo.getUserId();
        if ([
            SELECT COUNT()
            FROM PermissionSetAssignment
            WHERE AssigneeId = :userId
            AND PermissionSetId = :permissionSets[0].Id
        ] == 0) {
            insert new PermissionSetAssignment(
                AssigneeId = userId,
                PermissionSetId = permissionSets[0].Id
            );
        }
    }

    @IsTest
    static void returnsAttachedAndSuggestedArticlesForCase() {
        KnowledgeSuggestionController.resetCaches();
        Case caseRecord = new Case(
            Subject = 'Warranty compressor maintenance',
            Status = 'New'
        );
        insert caseRecord;

        Knowledge_Article__c attachedArticle = new Knowledge_Article__c(
            Name = 'Warranty compressor maintenance guide',
            Url_Name__c = 'warranty-compressor-maintenance-guide',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Warranty compressor steps.</p>'
        );
        Knowledge_Article__c suggestedArticle = new Knowledge_Article__c(
            Name = 'General compressor maintenance',
            Url_Name__c = 'general-compressor-maintenance',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Compressor maintenance overview.</p>'
        );
        insert new List<Knowledge_Article__c>{ attachedArticle, suggestedArticle };

        insert new Knowledge_Article_Link__c(
            Knowledge_Article__c = attachedArticle.Id,
            Related_Record_Id__c = String.valueOf(caseRecord.Id),
            Related_Object__c = 'Case'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals('Warranty compressor maintenance', response.searchText);
        System.assert(response.articles.size() >= 2, 'Expected attached and suggested articles.');

        Boolean foundAttached = false;
        Boolean foundSuggested = false;
        for (KnowledgeSuggestionController.ArticleSummary result : response.articles) {
            if (result.id == attachedArticle.Id && result.isAttached) {
                foundAttached = true;
            }
            if (result.id == suggestedArticle.Id && !result.isAttached) {
                foundSuggested = true;
            }
        }
        System.assert(foundAttached, 'Attached article should be returned.');
        System.assert(foundSuggested, 'Suggested article should match record subject terms.');
    }

    @IsTest
    static void attachArticleCreatesLinkWithoutDuplicate() {
        Case caseRecord = new Case(Subject = 'Leak inspection', Status = 'New');
        insert caseRecord;

        Knowledge_Article__c article = new Knowledge_Article__c(
            Name = 'Leak inspection checklist',
            Url_Name__c = 'leak-inspection-checklist',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Leak inspection steps.</p>'
        );
        insert article;

        Test.startTest();
        KnowledgeSuggestionController.attachArticle(caseRecord.Id, article.Id);
        KnowledgeSuggestionController.attachArticle(caseRecord.Id, article.Id);
        Test.stopTest();

        List<Knowledge_Article_Link__c> links = [
            SELECT Id
            FROM Knowledge_Article_Link__c
            WHERE Knowledge_Article__c = :article.Id
            AND Related_Record_Id__c = :String.valueOf(caseRecord.Id)
        ];
        System.assertEquals(1, links.size(), 'Only one link should exist per record and article.');
    }

    @IsTest
    static void sameArticleCanLinkToMultipleRecords() {
        Case firstCase = new Case(Subject = 'Compressor leak', Status = 'New');
        Case secondCase = new Case(Subject = 'Compressor leak follow up', Status = 'New');
        insert new List<Case>{ firstCase, secondCase };

        Knowledge_Article__c article = new Knowledge_Article__c(
            Name = 'Compressor leak inspection',
            Url_Name__c = 'compressor-leak-inspection',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Shared leak article.</p>'
        );
        insert article;

        Test.startTest();
        KnowledgeSuggestionController.attachArticle(firstCase.Id, article.Id);
        KnowledgeSuggestionController.attachArticle(secondCase.Id, article.Id);
        Test.stopTest();

        System.assertEquals(
            2,
            [SELECT COUNT() FROM Knowledge_Article_Link__c WHERE Knowledge_Article__c = :article.Id]
        );
    }

    @IsTest
    static void returnsArticlePreviewDetails() {
        Knowledge_Article__c article = new Knowledge_Article__c(
            Name = 'Geotab GPS Tracking Integration',
            Url_Name__c = 'geotab-gps-tracking-integration',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Integration overview for Geotab and FieldAx.</p>'
        );
        insert article;

        Test.startTest();
        KnowledgeSuggestionController.ArticlePreview preview =
            KnowledgeSuggestionController.getArticlePreview(article.Id);
        Test.stopTest();

        System.assertEquals(article.Id, preview.id);
        System.assertEquals('Geotab GPS Tracking Integration', preview.title);
        System.assertEquals('geotab-gps-tracking-integration', preview.urlName);
        System.assertEquals('Published', preview.status);
        System.assert(preview.articleBody.contains('Integration overview'));
    }

    @IsTest
    static void prioritizesSubjectTermsOverDescription() {
        Case caseRecord = new Case(
            Subject = 'Geotab GPS',
            Description = 'Need assistance with Air filter',
            Status = 'New'
        );
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'Geotab GPS Tracking Integration with Salesforce FieldAx',
            Url_Name__c = 'geotab-gps-tracking-integration',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Geotab integration overview.</p>'
        );
        insert new Knowledge_Article__c(
            Name = 'Air Filter Replacement Guide',
            Url_Name__c = 'air-filter-replacement-guide',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Air filter replacement steps.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals(1, response.articles.size());
        System.assertEquals(
            'Geotab GPS Tracking Integration with Salesforce FieldAx',
            response.articles[0].title
        );
    }

    @IsTest
    static void createArticleInsertsPublishedArticle() {
        Test.startTest();
        Id articleId = KnowledgeSuggestionController.createArticle(
            'The Most Common Air Compressor Failures (and How to Prevent Them)',
            'most-common-air-compressor-failures',
            '<p>Preventive maintenance overview.</p>',
            'Published',
            true
        );
        Test.stopTest();

        Knowledge_Article__c article = [
            SELECT Name, Url_Name__c, Status__c, Is_Visible_In_App__c
            FROM Knowledge_Article__c
            WHERE Id = :articleId
        ];
        System.assertEquals(
            'The Most Common Air Compressor Failures (and How to Prevent Them)',
            article.Name
        );
        System.assertEquals('most-common-air-compressor-failures', article.Url_Name__c);
        System.assertEquals('Published', article.Status__c);
        System.assertEquals(true, article.Is_Visible_In_App__c);
    }

    @IsTest
    static void createArticleRejectsDuplicateUrlName() {
        insert new Knowledge_Article__c(
            Name = 'Duplicate URL Article',
            Url_Name__c = 'duplicate-url-article',
            Status__c = 'Published',
            Is_Visible_In_App__c = true
        );

        try {
            KnowledgeSuggestionController.createArticle(
                'Another Article',
                'duplicate-url-article',
                '<p>Body</p>',
                'Published',
                true
            );
            System.assert(false, 'Duplicate URL Name should throw an error.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex);
        }
    }

    @IsTest
    static void createArticleRejectsInvalidStatus() {
        try {
            KnowledgeSuggestionController.createArticle(
                'Invalid Status Article',
                'invalid-status-article',
                '<p>Body</p>',
                'InvalidStatus',
                true
            );
            System.assert(false, 'Invalid status should throw an error.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex);
        }
    }

    @IsTest
    static void createArticleRequiresTitle() {
        try {
            KnowledgeSuggestionController.createArticle(
                '   ',
                'missing-title-article',
                '<p>Body</p>',
                'Draft',
                false
            );
            System.assert(false, 'Blank title should throw an error.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex);
        }
    }

    @IsTest
    static void attachArticleRequiresIds() {
        try {
            KnowledgeSuggestionController.attachArticle(null, null);
            System.assert(false, 'Missing ids should throw an error.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex);
        }
    }

    @IsTest
    static void getArticlePreviewThrowsForMissingArticle() {
        String prefix = Schema.SObjectType.Knowledge_Article__c.getKeyPrefix();
        Id missingArticleId = (Id) (prefix + '000000000AAA');

        try {
            KnowledgeSuggestionController.getArticlePreview(missingArticleId);
            System.assert(false, 'Missing article preview should throw an error.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex);
        }
    }

    @IsTest
    static void getKnowledgeForRecordReturnsEmptyForNullRecord() {
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(null, null, null);

        System.assertNotEquals(null, response.articles);
        System.assertEquals(0, response.articles.size());
    }

    @IsTest
    static void getArticlePreviewThrowsForNullId() {
        Boolean threw = false;
        try {
            KnowledgeSuggestionController.getArticlePreview(null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Null article Id should throw an error.');
    }

    @IsTest
    static void getKnowledgeThrowsForMissingRecord() {
        String prefix = Case.SObjectType.getDescribe().getKeyPrefix();
        Id missingCaseId = (Id) (prefix + '000000000AAA');
        Boolean threw = false;

        try {
            KnowledgeSuggestionController.getKnowledgeForRecord(missingCaseId, null, null);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Missing record should throw an error.');
    }

    @IsTest
    static void createArticleBuildsUrlNameWhenOmitted() {
        Test.startTest();
        Id articleId = KnowledgeSuggestionController.createArticle(
            'Auto URL Name Article',
            null,
            '<p>Body</p>',
            'Draft',
            false
        );
        Test.stopTest();

        Knowledge_Article__c article = [
            SELECT Url_Name__c, Status__c, Is_Visible_In_App__c
            FROM Knowledge_Article__c
            WHERE Id = :articleId
        ];
        System.assertEquals('auto-url-name-article', article.Url_Name__c);
        System.assertEquals('Draft', article.Status__c);
        System.assertEquals(false, article.Is_Visible_In_App__c);
    }

    @IsTest
    static void createArticleRejectsEmptyGeneratedUrlName() {
        Boolean threw = false;
        try {
            KnowledgeSuggestionController.createArticle('!!!', null, '<p>Body</p>', 'Draft', false);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Empty generated URL Name should throw an error.');
    }

    @IsTest
    static void createArticleTruncatesOversizedBody() {
        String hugeBody = 'x'.repeat(131100);

        Test.startTest();
        Id articleId = KnowledgeSuggestionController.createArticle(
            'Truncate Body Article',
            'truncate-body-article',
            hugeBody,
            'Review',
            true
        );
        Test.stopTest();

        Knowledge_Article__c article = [
            SELECT Article_Body__c, Status__c
            FROM Knowledge_Article__c
            WHERE Id = :articleId
        ];
        System.assertEquals(131072, article.Article_Body__c.length());
        System.assertEquals('Review', article.Status__c);
    }

    @IsTest
    static void getKnowledgeUsesSearchFieldOverride() {
        Case caseRecord = new Case(
            Subject = 'Override filter replacement',
            Status = 'New'
        );
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'Override filter replacement guide',
            Url_Name__c = 'override-filter-replacement-guide',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Override match body.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(
                caseRecord.Id,
                'Subject',
                null
            );
        Test.stopTest();

        System.assertEquals('Override filter replacement', response.searchText);
        System.assertEquals(1, response.articles.size());
        System.assertEquals('Override filter replacement guide', response.articles[0].title);
    }

    @IsTest
    static void suggestsArticlesFromDescriptionWhenSubjectHasNoTerms() {
        Case caseRecord = new Case(
            Subject = 'AB',
            Description = 'Geotab GPS integration support',
            Status = 'New'
        );
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'Geotab GPS integration support article',
            Url_Name__c = 'geotab-gps-integration-support-article',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Geotab support overview.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals(1, response.articles.size());
        System.assertEquals(
            'Geotab GPS integration support article',
            response.articles[0].title
        );
    }

    @IsTest
    static void fallsBackToVisibleArticlesWhenNoSearchTerms() {
        Case caseRecord = new Case(Subject = 'AB', Status = 'New');
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'Fallback visible article',
            Url_Name__c = 'fallback-visible-article',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Fallback article body.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals(1, response.articles.size());
        System.assertEquals('Fallback visible article', response.articles[0].title);
    }

    @IsTest
    static void getKnowledgeRejectsInvalidFieldOverride() {
        Case caseRecord = new Case(Subject = 'Validation test', Status = 'New');
        insert caseRecord;
        Boolean threw = false;

        try {
            KnowledgeSuggestionController.getKnowledgeForRecord(
                caseRecord.Id,
                'Invalid-Field',
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Invalid field API name should throw an error.');
    }

    @IsTest
    static void getKnowledgeRejectsMissingFieldOverride() {
        Case caseRecord = new Case(Subject = 'Validation test', Status = 'New');
        insert caseRecord;
        Boolean threw = false;

        try {
            KnowledgeSuggestionController.getKnowledgeForRecord(
                caseRecord.Id,
                'Does_Not_Exist__c',
                null
            );
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Missing field should throw an error.');
    }

    @IsTest
    static void attachArticleThrowsWhenArticleMissing() {
        Case caseRecord = new Case(Subject = 'Missing article test', Status = 'New');
        insert caseRecord;

        String prefix = Schema.SObjectType.Knowledge_Article__c.getKeyPrefix();
        Id missingArticleId = (Id) (prefix + '000000000AAA');
        Boolean threw = false;

        try {
            KnowledgeSuggestionController.attachArticle(caseRecord.Id, missingArticleId);
        } catch (AuraHandledException ex) {
            threw = true;
        }
        System.assert(threw, 'Missing article should throw an error.');
    }

    @IsTest
    static void excerptStripsHtmlAndTruncatesLongBody() {
        String longPlainText = 'A'.repeat(200);
        Knowledge_Article__c article = new Knowledge_Article__c(
            Name = 'HTML excerpt article',
            Url_Name__c = 'html-excerpt-article',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p><strong>' + longPlainText + '</strong></p>'
        );
        insert article;

        Case caseRecord = new Case(
            Subject = 'HTML excerpt article lookup',
            Status = 'New'
        );
        insert caseRecord;

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals(1, response.articles.size());
        System.assert(response.articles[0].excerpt.endsWith('...'));
        System.assertEquals(180, response.articles[0].excerpt.length());
    }

    @IsTest
    static void searchTermsEscapeLikeSpecialCharacters() {
        Case caseRecord = new Case(
            Subject = '100% warranty_compressor',
            Status = 'New'
        );
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'warranty compressor special checklist',
            Url_Name__c = 'warranty-compressor-special-checklist',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Special character search.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        System.assertEquals(1, response.articles.size());
        System.assertEquals('warranty compressor special checklist', response.articles[0].title);
    }

    @IsTest
    static void attachedDraftArticleIsExcludedFromResults() {
        Case caseRecord = new Case(Subject = 'Draft attachment test', Status = 'New');
        insert caseRecord;

        Knowledge_Article__c draftArticle = new Knowledge_Article__c(
            Name = 'Draft attachment article',
            Url_Name__c = 'draft-attachment-article',
            Status__c = 'Draft',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Draft only.</p>'
        );
        insert draftArticle;

        insert new Knowledge_Article_Link__c(
            Knowledge_Article__c = draftArticle.Id,
            Related_Record_Id__c = String.valueOf(caseRecord.Id),
            Related_Object__c = 'Case'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(caseRecord.Id, null, null);
        Test.stopTest();

        for (KnowledgeSuggestionController.ArticleSummary summary : response.articles) {
            System.assertNotEquals(draftArticle.Id, summary.id);
        }
    }

    @IsTest
    static void getKnowledgeUsesDescriptionFieldOverride() {
        Case caseRecord = new Case(
            Subject = 'AB',
            Description = 'Archived maintenance workflow',
            Status = 'New'
        );
        insert caseRecord;

        insert new Knowledge_Article__c(
            Name = 'Archived maintenance workflow guide',
            Url_Name__c = 'archived-maintenance-workflow-guide',
            Status__c = 'Published',
            Is_Visible_In_App__c = true,
            Article_Body__c = '<p>Workflow guide.</p>'
        );

        Test.startTest();
        KnowledgeSuggestionController.KnowledgeResponse response =
            KnowledgeSuggestionController.getKnowledgeForRecord(
                caseRecord.Id,
                'Subject',
                'Description'
            );
        Test.stopTest();

        System.assertEquals('AB', response.searchText);
        System.assertEquals(1, response.articles.size());
    }

    @IsTest
    static void createArticleSupportsArchivedStatus() {
        Test.startTest();
        Id articleId = KnowledgeSuggestionController.createArticle(
            'Archived maintenance article',
            'archived-maintenance-article',
            '<p>Archived body.</p>',
            'Archived',
            false
        );
        Test.stopTest();

        System.assertEquals(
            'Archived',
            [SELECT Status__c FROM Knowledge_Article__c WHERE Id = :articleId].Status__c
        );
    }

    @IsTest
    static void sanitizeLikeTermStripsWildcards() {
        System.assertEquals(
            '100 warranty compressor',
            KnowledgeSuggestionController.sanitizeLikeTerm('100% warranty_compressor')
        );
        System.assertEquals('', KnowledgeSuggestionController.sanitizeLikeTerm('ab'));
    }

    @IsTest
    static void buildUrlNameTrimsAndLimitsSlug() {
        System.assertEquals('', KnowledgeSuggestionController.buildUrlName(null));
        System.assertEquals('', KnowledgeSuggestionController.buildUrlName('   '));
        System.assertEquals(
            'the-most-common-air-compressor-failures',
            KnowledgeSuggestionController.buildUrlName(
                '  The Most Common Air Compressor Failures!!!  '
            )
        );
    }
}