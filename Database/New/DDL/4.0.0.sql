/****** Object:  UserDefinedTableType [dbo].[CategoryList]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE TYPE [dbo].[CategoryList] AS TABLE(
	[category] [nvarchar](255) NULL
)
GO
/****** Object:  StoredProcedure [dbo].[GetImplementationGuideTemplates]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
CREATE PROCEDURE [dbo].[GetImplementationGuideTemplates]
	@implementationGuideId INT,
	@inferred BIT,
	@parentTemplateId INT = NULL,
	@categories AS CategoryList READONLY
AS
BEGIN
	DECLARE @currentImplementationGuideId INT = @implementationGuideId, @relationshipCount INT, @retiredStatusId INT
	DECLARE @False BIT = 0, @True BIT = 1
	DECLARE @categoryCount INT

	SET @categoryCount = (SELECT COUNT(*) FROM @categories)

	CREATE TABLE #implementationGuides (id INT, [version] INT)
	CREATE TABLE #templates (id INT)
	CREATE TABLE #relationships (id INT)

	SEt @retiredStatusId = (SELECT id FROM publish_status WHERE [status] = 'Retired')

	WHILE (@currentImplementationGuideId IS NOT NULL)
	BEGIN
		INSERT INTO #implementationGuides (id, [version])
		SELECT @currentImplementationGuideId, [version] FROM implementationguide WHERE id = @currentImplementationGuideId

		SET @currentImplementationGuideId = (SELECT previousVersionImplementationGuideId FROM implementationguide WHERE id = @currentImplementationGuideId)
	END

	-- Loop through the IG versions from beginning to end adding/removing templates as appropriate
	IF (@parentTemplateId IS NULL)
	BEGIN
		DECLARE ig_cursor CURSOR
			FOR SELECT id FROM #implementationGuides ORDER BY [version]
		OPEN ig_cursor
		FETCH NEXT FROM ig_cursor INTO @currentImplementationGuideId;

		WHILE @@FETCH_STATUS = 0
		BEGIN
			DELETE FROM #templates
			WHERE id in (SELECT previousVersionTemplateId FROM template WHERE owningImplementationGuideId = @currentImplementationGuideId)

			INSERT INTO #templates (id)
			SELECT id FROM template WHERE owningImplementationGuideId = @currentImplementationGuideId

			FETCH NEXT FROM ig_cursor INTO @currentImplementationGuideId;
		END

		CLOSE ig_cursor;
		DEALLOCATE ig_cursor;
	END
	ELSE
	BEGIN
		INSERT INTO #templates
		SELECT @parentTemplateId
	END

	-- Remove any retired templates that aren't part of this version of the IG
	DELETE FROM #templates WHERE id IN (SELECT id FROM template WHERE owningImplementationGuideId != @implementationGuideId AND statusId = @retiredStatusId)

	insert_relationships:

	INSERT INTO #relationships (id)
	-- Contained templates
	SELECT tc.containedTemplateId AS id
	FROM template_constraint tc
		JOIN #templates tt ON tt.id = tc.templateId
	WHERE
		tc.containedTemplateId IS NOT NULL AND
		tc.containedTemplateId NOT IN (SELECT id FROM #templates) AND
		-- Either not filtering by categories, constraint's category is not set, or the category matches one of the specified categories
		(@categoryCount = 0 OR dbo.GetConstraintCategory(tc.id) = '' OR dbo.GetConstraintCategory(tc.id) IN (SELECT category FROM @categories))

	UNION ALL

	-- Implied templates
	SELECT t.impliedTemplateId
	FROM template t
		JOIN #templates tt ON tt.id = t.id
	WHERE
		t.impliedTemplateId IS NOT NULL AND
		t.impliedTemplateId NOT IN (SELECT id FROM #templates)

	IF (@inferred = 1)
	BEGIN
		INSERT INTO #templates
		SELECT id
		FROM #relationships
		SET @relationshipCount = @@ROWCOUNT
	END
	ELSE
	BEGIN
		INSERT INTO #templates
		SELECT #relationships.id
		FROM #relationships
			JOIN template t ON #relationships.id = t.id
			JOIN #implementationGuides ON t.owningImplementationGuideId = #implementationGuides.id
		SET @relationshipCount = @@ROWCOUNT
	END

	DELETE FROM #relationships

	IF (@relationshipCount > 0)
	BEGIN
		GOTO insert_relationships
	END

	SELECT DISTINCT id FROM #templates

	DROP TABLE #relationships
	DROP TABLE #templates
	DROP TABLE #implementationGuides
END

GO
/****** Object:  StoredProcedure [dbo].[SearchTemplates]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE PROCEDURE [dbo].[SearchTemplates]
	@userId INT = NULL,
	@filterImplementationGuideId INT = NULL,
	@filterName NVARCHAR(255) = NULL,
	@filterIdentifier NVARCHAR(255) = NULL,
	@filterTemplateTypeId INT = NULL,
	@filterOrganizationId INT = NULL,
	@filterContextType NVARCHAR(255) = NULL,
	@queryText NVARCHAR(255) = NULL
AS
BEGIN
	IF (@filterName = '') SET @filterName = NULL
	IF (@filterIdentifier = '') SET @filterIdentifier = NULL
	IF (@filterContextType = '') SET @filterContextType = NULL
	IF (@queryText = '') SET @queryText = NULL
	
	IF (@queryText IS NOT NULL) SET @queryText = '%' + @queryText + '%'

	DECLARE @userIsAdmin BIT = 0

	IF (@userId IS NOT NULL)
		SET @userIsAdmin = 
			CASE WHEN (SELECT COUNT(*) FROM user_role ur JOIN [role] r ON r.id = ur.roleId WHERE ur.userId = @userId AND isAdmin = 1) > 0 THEN 1
			ELSE 0 END

	CREATE TABLE #templateIds (id INT)

	-- Filter by implementation guide
	IF (@filterImplementationGuideId IS NOT NULL)
	BEGIN
		CREATE TABLE #implementationGuideTemplates (id INT)

		INSERT INTO #implementationGuideTemplates (id)
		EXEC GetImplementationGuideTemplates @implementationGuideId = @filterImplementationGuideId, @inferred = 1
		
		INSERT INTO #templateIds
		SELECT id FROM #implementationGuideTemplates
	END
	ELSE
	BEGIN
		INSERT INTO #templateIds (id)
		SELECT id FROM template
	END

	IF (@queryText IS NOT NULL OR @queryText != '')
	BEGIN
		CREATE TABLE #queryTextTemplates (id INT)

		INSERT INTO #queryTextTemplates (id)
		SELECT t.id
		FROM template t
			JOIN templatetype tt ON tt.id = t.templateTypeId
			JOIN implementationguide ig ON ig.id = t.owningImplementationGuideId
		WHERE
			t.name LIKE @queryText OR 
			t.oid LIKE @queryText OR
			tt.name LIKE @queryText OR
			ig.name LIKE @queryText OR
			EXISTS (SELECT * FROM template_constraint WHERE CONCAT(CAST(t.owningImplementationGuideId AS NVARCHAR), '-', CAST(number AS NVARCHAR)) LIKE @queryText AND template_constraint.templateId = t.id)

		DELETE FROM #templateIds
		WHERE id NOT IN (SELECT id FROM #queryTextTemplates)
	END

	IF (@userId IS NOT NULL AND @userIsAdmin = 0)
	BEGIN
		DELETE FROM #templateIds
		WHERE id NOT IN (SELECT templateId FROM v_templatePermissions WHERE userId = @userId AND permission = 'View')
	END
	
	SELECT t.id
	FROM v_templateList t
		JOIN #templateIds tid ON tid.id = t.id
	WHERE
		CHARINDEX(CASE WHEN @filterName IS NOT NULL THEN @filterName ELSE t.name END, t.name) > 0
		AND CHARINDEX(CASE WHEN @filterIdentifier IS NOT NULL THEN @filterIdentifier ELSE t.oid END, t.oid) > 0
		AND CHARINDEX(CASE WHEN @filterContextType IS NOT NULL THEN @filterContextType ELSE t.primaryContextType END, t.primaryContextType) > 0
		AND ISNULL(t.templateTypeId, 0) = CASE WHEN @filterTemplateTypeId IS NOT NULL THEN @filterTemplateTypeId ELSE ISNULL(t.templateTypeId, 0) END
		AND ISNULL(t.organizationId, 0) = CASE WHEN @filterOrganizationId IS NOT NULL THEN @filterOrganizationId ELSE ISNULL(t.organizationId, 0) END

	DROP TABLE #templateIds
END

GO
/****** Object:  StoredProcedure [dbo].[SearchValueSet]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE PROCEDURE [dbo].[SearchValueSet]
	@userId INT = NULL,
	@searchText VARCHAR(255) = '',
	@count INT = 20,
	@page INT = 1,
	@orderProperty VARCHAR(128) = 'Name',
	@orderDesc BIT = 0
AS
BEGIN
	DECLARE @searchTextAny VARCHAR(512)
	SET @searchTextAny = CONCAT('%', @searchText, '%')

	DECLARE @offset INT
	SET @offset = (@page - 1) * @count

	DECLARE @totalItems INT

	SELECT 
		ig.id as implementationGuideId,
		CASE WHEN igp.permission IS NOT NULL THEN 1 ELSE 0 END AS canEditImplementationGuide
	INTO #publishedImplementationGuides
	FROM implementationguide ig
		JOIN publish_status ps on ps.id = ig.publishStatusId
		LEFT JOIN v_implementationGuidePermissions igp on igp.implementationGuideId = ig.id AND igp.userId = @userId AND igp.permission = 'Edit'
	WHERE
		ps.[status] = 'Published'

	SELECT DISTINCT
		vs.id as valueSetId,
		pig.canEditImplementationGuide as canEdit
	INTO #publishedValueSets
	FROM valueset vs
		JOIN template_constraint tc on tc.valueSetId = vs.id
		JOIN template t on t.id = tc.templateId
		JOIN #publishedImplementationGuides pig on pig.implementationGuideId = t.owningImplementationGuideId

	CREATE TABLE #valuesets (
		id INT, 
		name VARCHAR(255), 
		oid VARCHAR(255), 
		code VARCHAR(255), 
		[description] NVARCHAR(max), 
		intensional BIT NULL, 
		intensionalDefinition NVARCHAR(max), 
		source NVARCHAR(1024), 
		isComplete BIT)

	INSERT INTO #valuesets
	SELECT DISTINCT
		vs.id,
		vs.name,
		vs.oid,
		vs.code,
		vs.[description],
		vs.intensional,
		vs.intensionalDefinition,
		vs.source,
		CAST(CASE 
			WHEN vs.isIncomplete = 0 THEN 1
			ELSE 0
		END AS BIT) AS isComplete
	FROM valueset vs
		LEFT JOIN valueset_member vsm ON vsm.valueSetId = vs.Id
		LEFT JOIN codesystem cs on vsm.codeSystemId = cs.id
	WHERE
		vs.code LIKE @searchTextAny
		OR vs.name LIKE @searchTextAny
		OR vs.oid LIKE @searchTextAny
		OR ISNULL(vs.description, '') LIKE @searchTextAny
		OR ISNULL(vs.source, '') LIKE @searchTextAny
		OR ISNULL(vsm.code, '') LIKE @searchTextAny
		OR ISNULL(vsm.displayName, '') LIKE @searchTextAny
		OR ISNULL(cs.name, '') LIKE @searchTextAny
		OR ISNULL(cs.oid, '') LIKE @searchTextAny

	SET @totalItems = (SELECT COUNT(*) FROM #valuesets)

	SELECT
		@totalItems as totalItems,
		vs.*,
		CAST(CASE WHEN p.publishedIgCount IS NULL OR p.publishedIgCount = 0 THEN 0 ELSE 1 END AS BIT) AS hasPublishedIg,
		CAST(CASE WHEN up.uneditablePublishedIgCount IS NULL OR up.uneditablePublishedIgCount = 0 THEN 1 ELSE 0 END AS BIT) AS canEditPublishedIg
	FROM #valuesets vs
		LEFT JOIN (SELECT valueSetId, COUNT(*) as publishedIgCount FROM #publishedValueSets group by valueSetId) AS p ON p.valueSetId = vs.id
		LEFT JOIN (SELECT valueSetId, COUNT(*) as uneditablePublishedIgCount FROM #publishedValueSets WHERE canEdit = 0 GROUP BY valueSetId) as up ON up.valueSetId = vs.id
	ORDER BY 
		CASE @orderDesc WHEN 0 THEN
			CASE @orderProperty
				WHEN 'Name' THEN vs.name
				WHEN 'Oid' THEN vs.oid
				WHEN 'IsComplete' THEN CAST(vs.isComplete as VARCHAR(255))
			END
		END ASC,
		CASE @orderDesc WHEN 1 THEN
			CASE @orderProperty
				WHEN 'Name' THEN vs.name
				WHEN 'Oid' THEN vs.oid
				WHEN 'IsComplete' THEN CAST(vs.isComplete as VARCHAR(255))
			END
		END DESC
	OFFSET @offset ROWS
	FETCH NEXT @count ROWS ONLY
END




GO
/****** Object:  UserDefinedFunction [dbo].[GetConstraintCategory]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE FUNCTION [dbo].[GetConstraintCategory] (@templateConstraintId INT)
RETURNS NVARCHAR(255)
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @constraintId INT
	DECLARE @category NVARCHAR(255)

	SET @constraintId = @templateConstraintId

	WHILE (@constraintId IS NOT NULL)
	BEGIN
		SET @category = (SELECT category FROM template_constraint WHERE id = @constraintId)

		IF (@category IS NOT NULL AND @category != '')
		BEGIN
			RETURN @category
		END

		SET @constraintId = (SELECT parentConstraintId FROM template_constraint WHERE id = @constraintId)	
	END

	RETURN ''
END;
GO
/****** Object:  UserDefinedFunction [dbo].[GetNextConformanceNumber]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE FUNCTION [dbo].[GetNextConformanceNumber] (
  @templateId INT)
RETURNS INT
BEGIN
  DECLARE @retValue INT
  DECLARE @implementationGuideId INT

  SET @implementationGuideId = (SELECT owningImplementationGuideId FROM template WHERE id = @templateId)

  IF (@implementationGuideId IS NULL)
  BEGIN
	  SET @retValue = (
		  SELECT ISNULL(MAX(tc.[number]), 0) + 1 FROM template t
			JOIN template_constraint tc ON tc.templateId = t.id
		  WHERE t.id = @templateId)
  END
  ELSE
  BEGIN
	  SET @retValue = (
		  SELECT ISNULL(MAX(tc.[number]), 0) + 1 FROM template t
			JOIN template_constraint tc ON tc.templateId = t.id
		  WHERE t.owningImplementationGuideId = @implementationGuideId)
  END

  RETURN @retValue
END

GO
/****** Object:  Table [dbo].[app_securable]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[app_securable](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](50) NOT NULL,
	[displayName] [nvarchar](255) NULL,
	[description] [ntext] NULL,
 CONSTRAINT [PK_app_securable] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[appsecurable_role]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[appsecurable_role](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[appSecurableId] [int] NOT NULL,
	[roleId] [int] NOT NULL,
 CONSTRAINT [PK_appsecurable_role] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[audit]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[audit](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[username] [nvarchar](255) NOT NULL,
	[auditDate] [datetime] NOT NULL,
	[ip] [nvarchar](50) NOT NULL,
	[type] [nvarchar](128) NOT NULL,
	[implementationGuideId] [int] NULL,
	[templateId] [int] NULL,
	[templateConstraintId] [int] NULL,
	[note] [nvarchar](max) NULL,
 CONSTRAINT [PK_audit] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[codesystem]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[codesystem](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[oid] [nvarchar](255) NOT NULL,
	[description] [nvarchar](max) NULL,
	[lastUpdate] [datetime] NULL,
 CONSTRAINT [PK_codesystem] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[green_constraint]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[green_constraint](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[greenTemplateId] [int] NOT NULL,
	[templateConstraintId] [int] NOT NULL,
	[parentGreenConstraintId] [int] NULL,
	[order] [int] NULL,
	[name] [nvarchar](255) NOT NULL,
	[description] [nvarchar](max) NULL,
	[isEditable] [bit] NOT NULL DEFAULT ((0)),
	[rootXPath] [nvarchar](250) NULL,
	[igtype_datatypeId] [int] NULL,
 CONSTRAINT [PK_green_constraint] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[green_template]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[green_template](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[parentGreenTemplateId] [int] NULL,
	[templateId] [int] NOT NULL,
	[order] [int] NULL,
	[name] [nvarchar](255) NOT NULL,
	[description] [nvarchar](max) NULL,
 CONSTRAINT [PK_green_template] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[group]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[group](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](100) NOT NULL,
	[organizationId] [int] NOT NULL,
 CONSTRAINT [PK_group] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[implementationguide](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideTypeId] [int] NOT NULL,
	[organizationId] [int] NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[publishDate] [datetime] NULL,
	[publishStatusId] [int] NULL,
	[previousVersionImplementationGuideId] [int] NULL DEFAULT (NULL),
	[version] [int] NULL DEFAULT ((1)),
	[displayName] [varchar](255) NULL,
	[accessManagerId] [int] NULL,
	[allowAccessRequests] [bit] NOT NULL CONSTRAINT [DF_implementationguide_allowAccessRequests]  DEFAULT ((0)),
	[webDisplayName] [nvarchar](255) NULL,
	[webDescription] [nvarchar](max) NULL,
	[webReadmeOverview] [nvarchar](max) NULL,
 CONSTRAINT [PK_implementationguide] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[implementationguide_file]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_file](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[fileName] [nvarchar](255) NOT NULL,
	[mimeType] [nvarchar](255) NOT NULL,
	[contentType] [nvarchar](255) NOT NULL,
	[expectedErrorCount] [int] NULL,
	[description] [ntext] NOT NULL DEFAULT (''),
	[url] [nvarchar](255) NULL,
 CONSTRAINT [PK_implementationguide_file] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_filedata]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_filedata](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideFileId] [int] NOT NULL,
	[data] [image] NOT NULL,
	[updatedDate] [datetime] NOT NULL,
	[updatedBy] [nvarchar](255) NOT NULL,
	[note] [nvarchar](max) NULL,
 CONSTRAINT [PK_implementationguide_filedata] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_permission]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_permission](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[permission] [nvarchar](50) NOT NULL,
	[type] [nvarchar](50) NOT NULL,
	[organizationId] [int] NULL,
	[groupId] [int] NULL,
	[userId] [int] NULL,
 CONSTRAINT [PK_implementationguide_permission] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_schpattern]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_schpattern](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[phase] [nvarchar](128) NOT NULL,
	[patternId] [nvarchar](255) NOT NULL,
	[patternContent] [nvarchar](max) NOT NULL,
 CONSTRAINT [PK_implementationguide_schpattern] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_section]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_section](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[heading] [nvarchar](255) NOT NULL,
	[content] [ntext] NULL,
	[order] [int] NOT NULL DEFAULT ((0)),
	[level] [int] NOT NULL DEFAULT ((1)),
 CONSTRAINT [PK_implementationguide_section_1] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_setting]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_setting](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[propertyName] [nvarchar](255) NOT NULL,
	[propertyValue] [nvarchar](max) NOT NULL,
 CONSTRAINT [PK_implementationguide_setting] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguide_templatetype]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguide_templatetype](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideId] [int] NOT NULL,
	[templateTypeId] [int] NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[detailsText] [nvarchar](max) NULL,
 CONSTRAINT [PK_implementationguide_templatetype] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguidetype]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguidetype](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[schemaLocation] [nvarchar](255) NOT NULL,
	[schemaPrefix] [nvarchar](255) NOT NULL,
	[schemaURI] [nvarchar](255) NOT NULL,
 CONSTRAINT [PK_implementationguidetype] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[implementationguidetype_datatype]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[implementationguidetype_datatype](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideTypeId] [int] NOT NULL,
	[dataTypeName] [nvarchar](255) NOT NULL,
 CONSTRAINT [PK_implementationguidetype_datatype] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[organization]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[organization](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[contactName] [nvarchar](128) NULL,
	[contactEmail] [nvarchar](255) NULL,
	[contactPhone] [nvarchar](50) NULL,
	[authProvider] [nvarchar](1024) NULL,
	[isInternal] [bit] NOT NULL DEFAULT ((0)),
 CONSTRAINT [PK_organization] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[organization_defaultpermission]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[organization_defaultpermission](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[organizationId] [int] NOT NULL,
	[permission] [nvarchar](50) NOT NULL,
	[type] [nvarchar](50) NOT NULL,
	[entireOrganizationId] [int] NULL,
	[groupId] [int] NULL,
	[userId] [int] NULL,
 CONSTRAINT [PK_organization_defaultpermission] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[publish_status]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[publish_status](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[status] [nvarchar](50) NOT NULL,
 CONSTRAINT [PK_publish_status] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[role]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[role](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](50) NULL,
	[isDefault] [bit] NOT NULL DEFAULT ((0)),
	[isAdmin] [bit] NOT NULL CONSTRAINT [DF_role_isAdmin]  DEFAULT ((0)),
 CONSTRAINT [PK_roles] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[role_restriction]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[role_restriction](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[roleId] [int] NOT NULL,
	[organizationId] [int] NOT NULL,
 CONSTRAINT [PK_role_restriction] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[template]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[template](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideTypeId] [int] NOT NULL,
	[templateTypeId] [int] NOT NULL,
	[organizationId] [int] NULL,
	[impliedTemplateId] [int] NULL,
	[owningImplementationGuideId] [int] NOT NULL,
	[oid] [nvarchar](255) NOT NULL,
	[isOpen] [bit] NOT NULL DEFAULT ((1)),
	[name] [nvarchar](255) NOT NULL,
	[bookmark] [nvarchar](255) NOT NULL,
	[description] [nvarchar](max) NULL,
	[primaryContext] [nvarchar](255) NULL,
	[notes] [nvarchar](max) NULL,
	[lastupdated] [date] NOT NULL DEFAULT (getdate()),
	[authorId] [int] NOT NULL,
	[previousVersionTemplateId] [int] NULL DEFAULT (NULL),
	[version] [int] NOT NULL DEFAULT ((1)),
	[primaryContextType] [nvarchar](255) NULL,
	[statusId] [int] NULL,
 CONSTRAINT [PK_template] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[template_constraint]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[template_constraint](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[number] [int] NULL,
	[templateId] [int] NOT NULL,
	[parentConstraintId] [int] NULL,
	[codeSystemId] [int] NULL,
	[valueSetId] [int] NULL,
	[containedTemplateId] [int] NULL,
	[order] [int] NOT NULL,
	[isBranch] [bit] NOT NULL DEFAULT ((0)),
	[isPrimitive] [bit] NOT NULL DEFAULT ((0)),
	[conformance] [nvarchar](128) NULL,
	[cardinality] [nvarchar](50) NULL,
	[context] [nvarchar](255) NULL,
	[dataType] [nvarchar](255) NULL,
	[valueConformance] [nvarchar](50) NULL,
	[isStatic] [bit] NULL,
	[value] [nvarchar](255) NULL,
	[displayName] [nvarchar](255) NULL,
	[valueSetDate] [datetime] NULL,
	[schematron] [nvarchar](max) NULL,
	[description] [nvarchar](max) NULL,
	[notes] [nvarchar](max) NULL,
	[primitiveText] [nvarchar](max) NULL,
	[isInheritable] [bit] NOT NULL DEFAULT ((1)),
	[label] [ntext] NULL,
	[isBranchIdentifier] [bit] NOT NULL DEFAULT ((0)),
	[isSchRooted] [bit] NOT NULL DEFAULT ((0)),
	[isHeading] [bit] NOT NULL DEFAULT ((0)),
	[headingDescription] [ntext] NULL,
	[category] [nvarchar](255) NULL,
	[displayNumber] [nvarchar](128) NULL,
	[isModifier] [bit] NOT NULL CONSTRAINT [DF_template_constraint_isModifier]  DEFAULT ((0)),
	[mustSupport] [bit] NOT NULL CONSTRAINT [DF_template_constraint_mustSupport]  DEFAULT ((0)),
 CONSTRAINT [PK_template_constraint] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[template_constraint_sample]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[template_constraint_sample](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[templateConstraintId] [int] NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[sampleText] [ntext] NOT NULL,
 CONSTRAINT [PK_template_constraint_sample] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[template_extension]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[template_extension](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[templateId] [int] NOT NULL,
	[identifier] [nvarchar](255) NOT NULL,
	[type] [nvarchar](55) NOT NULL,
	[value] [nvarchar](255) NOT NULL,
 CONSTRAINT [PK_template_extension] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[template_sample]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[template_sample](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[templateId] [int] NOT NULL,
	[lastUpdated] [date] NOT NULL DEFAULT (getdate()),
	[xmlSample] [text] NOT NULL,
	[name] [nvarchar](255) NOT NULL,
 CONSTRAINT [PK_Table_1] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[templatetype]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[templatetype](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[implementationGuideTypeId] [int] NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[outputOrder] [int] NOT NULL CONSTRAINT [DF_templatetype_outputOrder]  DEFAULT ((1)),
	[rootContext] [nvarchar](255) NULL,
	[rootContextType] [nvarchar](255) NULL,
 CONSTRAINT [PK_templatetype] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[user]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[user](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[userName] [nvarchar](50) NOT NULL,
	[organizationId] [int] NOT NULL,
	[firstName] [nvarchar](125) NOT NULL,
	[lastName] [nvarchar](125) NOT NULL,
	[email] [nvarchar](255) NOT NULL,
	[phone] [nvarchar](50) NOT NULL,
	[okayToContact] [bit] NULL,
	[externalOrganizationName] [nvarchar](50) NULL,
	[externalOrganizationType] [nvarchar](50) NULL,
	[apiKey] [nvarchar](255) NULL,
 CONSTRAINT [PK_user] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[user_group]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[user_group](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[userId] [int] NOT NULL,
	[groupId] [int] NOT NULL,
 CONSTRAINT [PK_user_group] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[user_role]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[user_role](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[roleId] [int] NOT NULL,
	[userId] [int] NOT NULL,
 CONSTRAINT [PK_user_role] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[valueset]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[valueset](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[oid] [nvarchar](255) NOT NULL,
	[name] [nvarchar](255) NOT NULL,
	[code] [nvarchar](255) NULL,
	[description] [nvarchar](max) NULL,
	[intensional] [bit] NULL,
	[intensionalDefinition] [nvarchar](max) NULL,
	[lastUpdate] [datetime] NULL,
	[source] [nvarchar](1024) NULL,
	[isIncomplete] [bit] NOT NULL DEFAULT ((0)),
 CONSTRAINT [PK_valueset] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[valueset_member]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[valueset_member](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[valueSetId] [int] NOT NULL,
	[codeSystemId] [int] NULL,
	[code] [nvarchar](255) NULL,
	[displayName] [nvarchar](1024) NULL,
	[status] [nvarchar](255) NULL DEFAULT ('active'),
	[statusDate] [datetime] NULL,
 CONSTRAINT [PK_valueset_member] PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  View [dbo].[v_constraintcount]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_constraintcount] AS 
select 
  template_constraint.templateId,
  count(*) AS total 
from template_constraint 
group by template_constraint.templateId;

GO
/****** Object:  View [dbo].[v_containedtemplatecount]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_containedtemplatecount] AS 
select 
  template_constraint.containedTemplateId AS containedTemplateId, 
  count(*) AS total 
from template_constraint 
group by template_constraint.containedTemplateId;

GO
/****** Object:  View [dbo].[v_impliedtemplatecount]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_impliedtemplatecount] AS 
select 
  template.impliedTemplateId AS impliedTemplateId, 
  count(*) AS total 
from template 
group by template.impliedTemplateId;

GO
/****** Object:  View [dbo].[v_template]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_template] AS
select
  t.id,
  t.oid,
  t.name,
  t.isOpen,
  ig.id as owningImplementationGuideId,
  ig.name as owningImplementationGuideTitle,
  igt.name as implementationGuideTypeName,
  tt.id as templateTypeId,
  tt.name as templateTypeName,
  ISNULL(t.primaryContext, tt.rootContext) as primaryContext,
  tt.name + ' (' + igt.name + ')' as templateTypeDisplay,
  o.name as organizationName,
  ig.publishDate,
  it.oid as impliedTemplateOid,
  it.name as impliedTemplateTitle,
  cc.total as constraintCount,
  ctc.total as containedTemplateCount,
  itc.total as impliedTemplateCount
from template t
  join implementationguidetype igt on igt.id = t.implementationGuideTypeId
  join templatetype tt on tt.id = t.templateTypeId
  left join implementationguide ig on ig.id = t.owningImplementationGuideId
  left join organization o on o.id = t.organizationId
  left join template it on it.id = t.impliedTemplateId
  left join v_constraintCount cc on cc.templateId = t.id
  left join v_containedTemplateCount ctc on ctc.containedTemplateId = t.id
  left join v_impliedTemplateCount itc on itc.impliedTemplateId = t.id;

GO
/****** Object:  View [dbo].[v_igaudittrail]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE VIEW [dbo].[v_igaudittrail]
AS
SELECT
	a.username, 
	a.auditDate, 
	a.ip, 
	a.type, 
	a.note, 
	ISNULL(a.implementationGuideId, t.owningImplementationGuideId) AS implementationGuideId, 
	a.templateId, 
	a.templateConstraintId, 
	t.name AS templateName,
	tc.number AS conformanceNumber
FROM
	audit AS a 
	LEFT JOIN template AS t ON t.id = a.templateId
	LEFT JOIN template_constraint tc ON tc.id = a.templateConstraintId


GO
/****** Object:  View [dbo].[v_implementationguidefile]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_implementationguidefile]
AS
select 
  igf.id AS id,
  igf.implementationGuideId AS implementationGuideId,
  igf.fileName AS fileName,
  igf.mimeType AS mimeType,
  igf.contentType AS contentType,
  igf.expectedErrorCount AS expectedErrorCount,
  igfd.data AS data,
  igfd.updatedDate AS updatedDate,
  igfd.updatedBy AS updatedBy,
  igfd.note AS note 
from implementationguide_file igf 
  join implementationguide_filedata igfd on igfd.implementationGuideFileId = igf.id

GO
/****** Object:  View [dbo].[v_implementationGuidePermissions]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
CREATE VIEW [dbo].[v_implementationGuidePermissions] AS

select distinct userId, implementationGuideId, permission
from (
	select u.id as userId, igp.implementationGuideId as implementationGuideId, igp.permission as permission
	from [user] u
	  join implementationguide_permission igp on igp.organizationId = u.organizationId

	union all

	select u.id, igp.implementationGuideId, igp.permission
	from [user] u
	  join user_group ug on ug.userId = u.id
	  join implementationguide_permission igp on igp.groupId = ug.groupId

	union all

	select u.id, igp.implementationGuideId, igp.permission
	from [user] u
	  join implementationguide_permission igp on igp.userId = u.id
) p
GO
/****** Object:  View [dbo].[v_implementationGuideTemplates]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE VIEW [dbo].[v_implementationGuideTemplates] AS
	WITH versionedTemplateIgs 
	AS (
		select t.id as templateId, nig.id as implementationGuideId
		from template t
			left join template nt on nt.previousVersionTemplateId	= t.id
			join implementationguide nig on nig.previousVersionImplementationGuideId = t.owningImplementationGuideId
		where nt.id is null and nig.id is not null

		union all

		select vig.templateId, nig.id
		from versionedTemplateIgs vig
		join implementationguide nig on nig.previousVersionImplementationGuideId = vig.implementationGuideId
	)

	select ig.id as implementationGuideId, t.id as templateId 
	from implementationguide ig
		join template t on t.owningImplementationGuideId = ig.id

	union all

	select ig.id, vig.templateId
	from implementationguide ig
		join versionedTemplateIgs	vig on vig.implementationGuideId = ig.id

GO
/****** Object:  View [dbo].[v_latestimplementationguidefiledata]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE VIEW [dbo].[v_latestimplementationguidefiledata]
AS
select 
  igfd.id AS id,
  igfd.implementationGuideFileId AS implementationGuideFileId,
  igfd.data AS data,
  igfd.updatedDate AS updatedDate,
  igfd.updatedBy AS updatedBy,
  igfd.note AS note
from implementationguide_file igf
  join implementationguide_filedata igfd on igfd.updatedDate = (select max(updatedDate) from implementationguide_filedata where implementationGuideFileId = igf.id)

GO
/****** Object:  View [dbo].[v_templateList]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
CREATE VIEW [dbo].[v_templateList]
WITH SCHEMABINDING
AS
select 
  t1.id,
  t1.name,
  t1.oid,
  CASE 
    WHEN t1.isOpen = 1 THEN 'Yes'
	ELSE 'No' END AS [open],
  tt.name + ' (' + igt.name + ')' as templateType,
  tt.id as templateTypeId,
  CASE WHEN ig.[version] != 1 THEN ig.name + ' V' + CAST(ig.[version] AS VARCHAR(10)) ELSE ig.name END as implementationGuide,
  ig.id as implementationGuideId,
  o.name as organization,
  o.id as organizationId,
  ig.publishDate as publishDate,
  it.name as impliedTemplateName,
  it.oid as impliedTemplateOid,
  it.id as impliedTemplateId,
  t1.[description],
  t1.primaryContextType
from dbo.template t1
  join dbo.implementationguidetype igt on igt.id = t1.implementationGuideTypeId
  join dbo.templatetype tt on tt.id = t1.templateTypeId
  left join dbo.implementationguide ig on ig.id = t1.owningImplementationGuideId
  left join dbo.organization o on o.id = t1.organizationId
  left join dbo.template it on it.id = t1.impliedTemplateId

GO
/****** Object:  View [dbo].[v_templatePermissions]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE VIEW [dbo].[v_templatePermissions] AS

select distinct userId, templateId, permission
from (
	-- templates not associated with an ig are available to everyone
	select u.id as userId, t.id as templateId, 'View' as permission
	from [user] u, 
	  template t
	where t.owningImplementationGuideId is null

	union all

	select u.id, t.id, 'Edit'
	from [user] u, 
	  template t
	where t.owningImplementationGuideId is null

	union all

	-- templates associated with implementation guides
	-- the entire organization is available
	select u.id, t.id, igp.permission
	from [user] u
	  join implementationguide_permission igp on igp.organizationId = u.organizationId
	  join template t on t.owningImplementationGuideId = igp.implementationGuideId

	union all 

	-- templates associated with implementation guides
	-- the user is part of a group given permission
	select u.id, t.id, igp.permission
	from [user] u
	  join user_group ug on ug.userId = u.id
	  join implementationguide_permission igp on igp.groupId = ug.groupId
	  join template t on t.owningImplementationGuideId = igp.implementationGuideId

	union all 

	-- templates associated with an implementation guide
	-- the user is assigned directly to the ig
	select u.id, t.id, igp.permission
	from [user] u
	  join implementationguide_permission igp on igp.userId = u.id
	  join template t on t.owningImplementationGuideId = igp.implementationGuideId
) p

GO
/****** Object:  View [dbo].[v_templateusage]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
create view [dbo].[v_templateusage] as
select distinct 
  t.id as templateId, 
  t.name + ' (' + t.oid + ')' as templateDisplay,
  ig.id as implementationGuideId,
  ig.name + ' (' + igt.name + ')' as implementationGuideDisplay
from template t
join implementationguide ig on t.owningImplementationGuideId = ig.id
join implementationguidetype igt on igt.id = ig.implementationGuideTypeId

union all

select distinct 
  t.id as templateId, 
  t.name + ' (' + t.oid + ')' as templateDisplay,
  ig.id as implementationGuideId,
  ig.name + ' (' + igt.name + ')' as implementationGuideDisplay
from template t
join template_constraint tc on t.id = tc.containedTemplateId
join template t2 on t2.id = tc.templateId
join implementationguide ig on t2.owningImplementationGuideId = ig.id
join implementationguidetype igt on igt.id = ig.implementationGuideTypeId

union all

select distinct 
  t.id as templateId,
  t.name + ' (' + t.oid + ')' as templateDisplay,
  ig.id as implementationGuideId,
  ig.name + ' (' + igt.name + ')' as implementationGuideDisplay
from template t
join template t2 on t2.impliedTemplateId = t.id
join implementationguide ig on t2.owningImplementationGuideId = ig.id
join implementationguidetype igt on igt.id = ig.implementationGuideTypeId

GO
/****** Object:  View [dbo].[v_userSecurables]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

CREATE VIEW [dbo].[v_userSecurables] AS

select distinct ur.userId, [as].name 
from user_role ur
  join appsecurable_role asr on asr.roleId = ur.roleId
  join app_securable [as] on [as].id = asr.appSecurableId


GO
/****** Object:  Index [IDX_green_constraint_greentemplateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_green_constraint_greentemplateId] ON [dbo].[green_constraint]
(
	[greenTemplateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_green_constraint_parentGreenConstraintId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_green_constraint_parentGreenConstraintId] ON [dbo].[green_constraint]
(
	[parentGreenConstraintId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_green_constraint_templateConstraintId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_green_constraint_templateConstraintId] ON [dbo].[green_constraint]
(
	[templateConstraintId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_green_template_parentGreenTemplateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_green_template_parentGreenTemplateId] ON [dbo].[green_template]
(
	[parentGreenTemplateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_green_template_templateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_green_template_templateId] ON [dbo].[green_template]
(
	[templateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_implementationGuideTypeId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_implementationGuideTypeId] ON [dbo].[implementationguide]
(
	[implementationGuideTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_organizationid]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_organizationid] ON [dbo].[implementationguide]
(
	[organizationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_file_implementationGuideId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_file_implementationGuideId] ON [dbo].[implementationguide_file]
(
	[implementationGuideId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_filedata_implementationguideFileId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_filedata_implementationguideFileId] ON [dbo].[implementationguide_filedata]
(
	[implementationGuideFileId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_schpattern_implementationGuideId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_schpattern_implementationGuideId] ON [dbo].[implementationguide_schpattern]
(
	[implementationGuideId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_setting_implementationguideId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_setting_implementationguideId] ON [dbo].[implementationguide_setting]
(
	[implementationGuideId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_templatetype_implementationguideid]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_templatetype_implementationguideid] ON [dbo].[implementationguide_templatetype]
(
	[implementationGuideId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguide_templatetype_templateTypeId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguide_templatetype_templateTypeId] ON [dbo].[implementationguide_templatetype]
(
	[templateTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_implementationguidetype_datatype_implementationguidetypeid]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_implementationguidetype_datatype_implementationguidetypeid] ON [dbo].[implementationguidetype_datatype]
(
	[implementationGuideTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_implementationGuideTypeId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_implementationGuideTypeId] ON [dbo].[template]
(
	[implementationGuideTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_impliedTemplateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_impliedTemplateId] ON [dbo].[template]
(
	[impliedTemplateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
/****** Object:  Index [IDX_template_name]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_name] ON [dbo].[template]
(
	[name] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
/****** Object:  Index [IDX_template_oid]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_oid] ON [dbo].[template]
(
	[oid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_organizationId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_organizationId] ON [dbo].[template]
(
	[organizationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_templateTypeId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_templateTypeId] ON [dbo].[template]
(
	[templateTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_constraint_codeSystemId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_constraint_codeSystemId] ON [dbo].[template_constraint]
(
	[codeSystemId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_constraint_containedTemplateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_constraint_containedTemplateId] ON [dbo].[template_constraint]
(
	[containedTemplateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_constraint_parentConstraintId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_constraint_parentConstraintId] ON [dbo].[template_constraint]
(
	[parentConstraintId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_constraint_templateId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_constraint_templateId] ON [dbo].[template_constraint]
(
	[templateId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_template_constraint_valueSetId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_template_constraint_valueSetId] ON [dbo].[template_constraint]
(
	[valueSetId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_templatetype_implementationGuideTypeId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_templatetype_implementationGuideTypeId] ON [dbo].[templatetype]
(
	[implementationGuideTypeId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
/****** Object:  Index [IDX_valueset_name]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_valueset_name] ON [dbo].[valueset]
(
	[name] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
/****** Object:  Index [IDX_valueset_oid]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_valueset_oid] ON [dbo].[valueset]
(
	[oid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_valueset_member_]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_valueset_member_] ON [dbo].[valueset_member]
(
	[codeSystemId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_valueset_member_valuesetId]    Script Date: 7/5/2016 12:18:00 PM ******/
CREATE NONCLUSTERED INDEX [IDX_valueset_member_valuesetId] ON [dbo].[valueset_member]
(
	[valueSetId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
ALTER TABLE [dbo].[appsecurable_role]  WITH CHECK ADD  CONSTRAINT [FK_appsecurable_role_appsecurable] FOREIGN KEY([appSecurableId])
REFERENCES [dbo].[app_securable] ([id])
GO
ALTER TABLE [dbo].[appsecurable_role] CHECK CONSTRAINT [FK_appsecurable_role_appsecurable]
GO
ALTER TABLE [dbo].[appsecurable_role]  WITH CHECK ADD  CONSTRAINT [FK_appsecurable_role_roles] FOREIGN KEY([roleId])
REFERENCES [dbo].[role] ([id])
GO
ALTER TABLE [dbo].[appsecurable_role] CHECK CONSTRAINT [FK_appsecurable_role_roles]
GO
ALTER TABLE [dbo].[green_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_green_constraint_green_constraint1] FOREIGN KEY([parentGreenConstraintId])
REFERENCES [dbo].[green_constraint] ([id])
GO
ALTER TABLE [dbo].[green_constraint] CHECK CONSTRAINT [FK_green_constraint_green_constraint1]
GO
ALTER TABLE [dbo].[green_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_green_constraint_green_template] FOREIGN KEY([greenTemplateId])
REFERENCES [dbo].[green_template] ([id])
GO
ALTER TABLE [dbo].[green_constraint] CHECK CONSTRAINT [FK_green_constraint_green_template]
GO
ALTER TABLE [dbo].[green_constraint]  WITH CHECK ADD  CONSTRAINT [FK_green_constraint_igtype_datatype] FOREIGN KEY([igtype_datatypeId])
REFERENCES [dbo].[implementationguidetype_datatype] ([id])
GO
ALTER TABLE [dbo].[green_constraint] CHECK CONSTRAINT [FK_green_constraint_igtype_datatype]
GO
ALTER TABLE [dbo].[green_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_green_constraint_template_constraint] FOREIGN KEY([templateConstraintId])
REFERENCES [dbo].[template_constraint] ([id])
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[green_constraint] CHECK CONSTRAINT [FK_green_constraint_template_constraint]
GO
ALTER TABLE [dbo].[green_template]  WITH NOCHECK ADD  CONSTRAINT [FK_green_template_green_template] FOREIGN KEY([parentGreenTemplateId])
REFERENCES [dbo].[green_template] ([id])
GO
ALTER TABLE [dbo].[green_template] CHECK CONSTRAINT [FK_green_template_green_template]
GO
ALTER TABLE [dbo].[green_template]  WITH NOCHECK ADD  CONSTRAINT [FK_green_template_template] FOREIGN KEY([templateId])
REFERENCES [dbo].[template] ([id])
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[green_template] CHECK CONSTRAINT [FK_green_template_template]
GO
ALTER TABLE [dbo].[group]  WITH CHECK ADD  CONSTRAINT [FK_group_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[group] CHECK CONSTRAINT [FK_group_organization]
GO
ALTER TABLE [dbo].[implementationguide]  WITH CHECK ADD  CONSTRAINT [FK_ig_igPreviousVersion] FOREIGN KEY([previousVersionImplementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide] CHECK CONSTRAINT [FK_ig_igPreviousVersion]
GO
ALTER TABLE [dbo].[implementationguide]  WITH NOCHECK ADD  CONSTRAINT [FK_implementationguide_implementationguidetype] FOREIGN KEY([implementationGuideTypeId])
REFERENCES [dbo].[implementationguidetype] ([id])
GO
ALTER TABLE [dbo].[implementationguide] CHECK CONSTRAINT [FK_implementationguide_implementationguidetype]
GO
ALTER TABLE [dbo].[implementationguide]  WITH NOCHECK ADD  CONSTRAINT [FK_implementationguide_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[implementationguide] CHECK CONSTRAINT [FK_implementationguide_organization]
GO
ALTER TABLE [dbo].[implementationguide]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_publish_status] FOREIGN KEY([publishStatusId])
REFERENCES [dbo].[publish_status] ([id])
GO
ALTER TABLE [dbo].[implementationguide] CHECK CONSTRAINT [FK_implementationguide_publish_status]
GO
ALTER TABLE [dbo].[implementationguide]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_user] FOREIGN KEY([accessManagerId])
REFERENCES [dbo].[user] ([id])
GO
ALTER TABLE [dbo].[implementationguide] CHECK CONSTRAINT [FK_implementationguide_user]
GO
ALTER TABLE [dbo].[implementationguide_file]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_file_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_file] CHECK CONSTRAINT [FK_implementationguide_file_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_filedata]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_filedata_implementationguide_file] FOREIGN KEY([implementationGuideFileId])
REFERENCES [dbo].[implementationguide_file] ([id])
GO
ALTER TABLE [dbo].[implementationguide_filedata] CHECK CONSTRAINT [FK_implementationguide_filedata_implementationguide_file]
GO
ALTER TABLE [dbo].[implementationguide_permission]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_permission_group] FOREIGN KEY([groupId])
REFERENCES [dbo].[group] ([id])
GO
ALTER TABLE [dbo].[implementationguide_permission] CHECK CONSTRAINT [FK_implementationguide_permission_group]
GO
ALTER TABLE [dbo].[implementationguide_permission]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_permission_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_permission] CHECK CONSTRAINT [FK_implementationguide_permission_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_permission]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_permission_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[implementationguide_permission] CHECK CONSTRAINT [FK_implementationguide_permission_organization]
GO
ALTER TABLE [dbo].[implementationguide_permission]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_permission_user] FOREIGN KEY([userId])
REFERENCES [dbo].[user] ([id])
GO
ALTER TABLE [dbo].[implementationguide_permission] CHECK CONSTRAINT [FK_implementationguide_permission_user]
GO
ALTER TABLE [dbo].[implementationguide_schpattern]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_schpattern_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_schpattern] CHECK CONSTRAINT [FK_implementationguide_schpattern_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_section]  WITH CHECK ADD  CONSTRAINT [FK_implementationguide_section_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_section] CHECK CONSTRAINT [FK_implementationguide_section_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_setting]  WITH NOCHECK ADD  CONSTRAINT [FK_implementationguide_setting_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_setting] CHECK CONSTRAINT [FK_implementationguide_setting_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_templatetype]  WITH NOCHECK ADD  CONSTRAINT [FK_implementationguide_templatetype_implementationguide] FOREIGN KEY([implementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[implementationguide_templatetype] CHECK CONSTRAINT [FK_implementationguide_templatetype_implementationguide]
GO
ALTER TABLE [dbo].[implementationguide_templatetype]  WITH NOCHECK ADD  CONSTRAINT [FK_implementationguide_templatetype_templatetype] FOREIGN KEY([templateTypeId])
REFERENCES [dbo].[templatetype] ([id])
GO
ALTER TABLE [dbo].[implementationguide_templatetype] CHECK CONSTRAINT [FK_implementationguide_templatetype_templatetype]
GO
ALTER TABLE [dbo].[implementationguidetype_datatype]  WITH CHECK ADD  CONSTRAINT [FK_implementationguidetype_datatype_implementationguidetype] FOREIGN KEY([implementationGuideTypeId])
REFERENCES [dbo].[implementationguidetype] ([id])
GO
ALTER TABLE [dbo].[implementationguidetype_datatype] CHECK CONSTRAINT [FK_implementationguidetype_datatype_implementationguidetype]
GO
ALTER TABLE [dbo].[organization_defaultpermission]  WITH CHECK ADD  CONSTRAINT [FK_organization_defaultpermission_group] FOREIGN KEY([groupId])
REFERENCES [dbo].[group] ([id])
GO
ALTER TABLE [dbo].[organization_defaultpermission] CHECK CONSTRAINT [FK_organization_defaultpermission_group]
GO
ALTER TABLE [dbo].[organization_defaultpermission]  WITH CHECK ADD  CONSTRAINT [FK_organization_defaultpermission_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[organization_defaultpermission] CHECK CONSTRAINT [FK_organization_defaultpermission_organization]
GO
ALTER TABLE [dbo].[organization_defaultpermission]  WITH CHECK ADD  CONSTRAINT [FK_organization_defaultpermission_organization1] FOREIGN KEY([entireOrganizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[organization_defaultpermission] CHECK CONSTRAINT [FK_organization_defaultpermission_organization1]
GO
ALTER TABLE [dbo].[organization_defaultpermission]  WITH CHECK ADD  CONSTRAINT [FK_organization_defaultpermission_user] FOREIGN KEY([userId])
REFERENCES [dbo].[user] ([id])
GO
ALTER TABLE [dbo].[organization_defaultpermission] CHECK CONSTRAINT [FK_organization_defaultpermission_user]
GO
ALTER TABLE [dbo].[role_restriction]  WITH CHECK ADD  CONSTRAINT [FK_role_restriction_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[role_restriction] CHECK CONSTRAINT [FK_role_restriction_organization]
GO
ALTER TABLE [dbo].[role_restriction]  WITH CHECK ADD  CONSTRAINT [FK_role_restriction_roles] FOREIGN KEY([roleId])
REFERENCES [dbo].[role] ([id])
GO
ALTER TABLE [dbo].[role_restriction] CHECK CONSTRAINT [FK_role_restriction_roles]
GO
ALTER TABLE [dbo].[template]  WITH NOCHECK ADD  CONSTRAINT [FK_template_implementationguide] FOREIGN KEY([owningImplementationGuideId])
REFERENCES [dbo].[implementationguide] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_implementationguide]
GO
ALTER TABLE [dbo].[template]  WITH NOCHECK ADD  CONSTRAINT [FK_template_implementationguidetype] FOREIGN KEY([implementationGuideTypeId])
REFERENCES [dbo].[implementationguidetype] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_implementationguidetype]
GO
ALTER TABLE [dbo].[template]  WITH NOCHECK ADD  CONSTRAINT [FK_template_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_organization]
GO
ALTER TABLE [dbo].[template]  WITH CHECK ADD  CONSTRAINT [FK_template_status] FOREIGN KEY([statusId])
REFERENCES [dbo].[publish_status] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_status]
GO
ALTER TABLE [dbo].[template]  WITH NOCHECK ADD  CONSTRAINT [FK_template_template] FOREIGN KEY([impliedTemplateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_template]
GO
ALTER TABLE [dbo].[template]  WITH CHECK ADD  CONSTRAINT [FK_template_templatePreviousVersion] FOREIGN KEY([previousVersionTemplateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_templatePreviousVersion]
GO
ALTER TABLE [dbo].[template]  WITH NOCHECK ADD  CONSTRAINT [FK_template_templatetype] FOREIGN KEY([templateTypeId])
REFERENCES [dbo].[templatetype] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_templatetype]
GO
ALTER TABLE [dbo].[template]  WITH CHECK ADD  CONSTRAINT [FK_template_user] FOREIGN KEY([authorId])
REFERENCES [dbo].[user] ([id])
GO
ALTER TABLE [dbo].[template] CHECK CONSTRAINT [FK_template_user]
GO
ALTER TABLE [dbo].[template_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_template_constraint_codesystem] FOREIGN KEY([codeSystemId])
REFERENCES [dbo].[codesystem] ([id])
GO
ALTER TABLE [dbo].[template_constraint] CHECK CONSTRAINT [FK_template_constraint_codesystem]
GO
ALTER TABLE [dbo].[template_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_template_constraint_template] FOREIGN KEY([templateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template_constraint] CHECK CONSTRAINT [FK_template_constraint_template]
GO
ALTER TABLE [dbo].[template_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_template_constraint_template_constraint1] FOREIGN KEY([parentConstraintId])
REFERENCES [dbo].[template_constraint] ([id])
GO
ALTER TABLE [dbo].[template_constraint] CHECK CONSTRAINT [FK_template_constraint_template_constraint1]
GO
ALTER TABLE [dbo].[template_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_template_constraint_template1] FOREIGN KEY([containedTemplateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template_constraint] CHECK CONSTRAINT [FK_template_constraint_template1]
GO
ALTER TABLE [dbo].[template_constraint]  WITH NOCHECK ADD  CONSTRAINT [FK_template_constraint_valueset] FOREIGN KEY([valueSetId])
REFERENCES [dbo].[valueset] ([id])
GO
ALTER TABLE [dbo].[template_constraint] CHECK CONSTRAINT [FK_template_constraint_valueset]
GO
ALTER TABLE [dbo].[template_constraint_sample]  WITH CHECK ADD  CONSTRAINT [FK_template_constraint_sample_template_constraint] FOREIGN KEY([templateConstraintId])
REFERENCES [dbo].[template_constraint] ([id])
GO
ALTER TABLE [dbo].[template_constraint_sample] CHECK CONSTRAINT [FK_template_constraint_sample_template_constraint]
GO
ALTER TABLE [dbo].[template_extension]  WITH CHECK ADD  CONSTRAINT [FK_template_extension_template] FOREIGN KEY([templateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template_extension] CHECK CONSTRAINT [FK_template_extension_template]
GO
ALTER TABLE [dbo].[template_sample]  WITH CHECK ADD  CONSTRAINT [FK_templatesample_template] FOREIGN KEY([templateId])
REFERENCES [dbo].[template] ([id])
GO
ALTER TABLE [dbo].[template_sample] CHECK CONSTRAINT [FK_templatesample_template]
GO
ALTER TABLE [dbo].[templatetype]  WITH NOCHECK ADD  CONSTRAINT [FK_templatetype_implementationguidetype] FOREIGN KEY([implementationGuideTypeId])
REFERENCES [dbo].[implementationguidetype] ([id])
GO
ALTER TABLE [dbo].[templatetype] CHECK CONSTRAINT [FK_templatetype_implementationguidetype]
GO
ALTER TABLE [dbo].[user]  WITH CHECK ADD  CONSTRAINT [FK_user_organization] FOREIGN KEY([organizationId])
REFERENCES [dbo].[organization] ([id])
GO
ALTER TABLE [dbo].[user] CHECK CONSTRAINT [FK_user_organization]
GO
ALTER TABLE [dbo].[user_group]  WITH CHECK ADD  CONSTRAINT [FK_user_group_group] FOREIGN KEY([groupId])
REFERENCES [dbo].[group] ([id])
ON UPDATE CASCADE
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[user_group] CHECK CONSTRAINT [FK_user_group_group]
GO
ALTER TABLE [dbo].[user_group]  WITH CHECK ADD  CONSTRAINT [FK_user_group_user] FOREIGN KEY([userId])
REFERENCES [dbo].[user] ([id])
GO
ALTER TABLE [dbo].[user_group] CHECK CONSTRAINT [FK_user_group_user]
GO
ALTER TABLE [dbo].[user_role]  WITH CHECK ADD  CONSTRAINT [FK_user_role_roles] FOREIGN KEY([roleId])
REFERENCES [dbo].[role] ([id])
ON UPDATE CASCADE
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[user_role] CHECK CONSTRAINT [FK_user_role_roles]
GO
ALTER TABLE [dbo].[user_role]  WITH CHECK ADD  CONSTRAINT [FK_user_role_user] FOREIGN KEY([userId])
REFERENCES [dbo].[user] ([id])
ON UPDATE CASCADE
ON DELETE CASCADE
GO
ALTER TABLE [dbo].[user_role] CHECK CONSTRAINT [FK_user_role_user]
GO
ALTER TABLE [dbo].[valueset_member]  WITH NOCHECK ADD  CONSTRAINT [FK_valueset_member_codesystem] FOREIGN KEY([codeSystemId])
REFERENCES [dbo].[codesystem] ([id])
GO
ALTER TABLE [dbo].[valueset_member] CHECK CONSTRAINT [FK_valueset_member_codesystem]
GO
ALTER TABLE [dbo].[valueset_member]  WITH NOCHECK ADD  CONSTRAINT [FK_valueset_member_valueset] FOREIGN KEY([valueSetId])
REFERENCES [dbo].[valueset] ([id])
GO
ALTER TABLE [dbo].[valueset_member] CHECK CONSTRAINT [FK_valueset_member_valueset]
GO
/****** Object:  Trigger [dbo].[ConformanceNumberTrigger]    Script Date: 7/5/2016 12:18:00 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

create trigger [dbo].[ConformanceNumberTrigger] on [dbo].[template_constraint]
after insert, update
as
   SET NoCount ON
   DECLARE @constraintId INT
   DECLARE @templateId INT

   IF EXISTS (SELECT * FROM INSERTED WHERE [number] IS NULL)
   BEGIN
     SET @constraintId = (SELECT id FROM INSERTED)
	 SET @templateId = (SELECT templateId FROM INSERTED)

     UPDATE template_constraint SET [number] = dbo.GetNextConformanceNumber(@templateId)
	 WHERE id = @constraintId
   END


GO
EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPane1', @value=N'[0E232FF0-B466-11cf-A24F-00AA00A3EFFF, 1.00]
Begin DesignProperties = 
   Begin PaneConfigurations = 
      Begin PaneConfiguration = 0
         NumPanes = 4
         Configuration = "(H (1[40] 4[20] 2[20] 3) )"
      End
      Begin PaneConfiguration = 1
         NumPanes = 3
         Configuration = "(H (1 [50] 4 [25] 3))"
      End
      Begin PaneConfiguration = 2
         NumPanes = 3
         Configuration = "(H (1 [50] 2 [25] 3))"
      End
      Begin PaneConfiguration = 3
         NumPanes = 3
         Configuration = "(H (4 [30] 2 [40] 3))"
      End
      Begin PaneConfiguration = 4
         NumPanes = 2
         Configuration = "(H (1 [56] 3))"
      End
      Begin PaneConfiguration = 5
         NumPanes = 2
         Configuration = "(H (2 [66] 3))"
      End
      Begin PaneConfiguration = 6
         NumPanes = 2
         Configuration = "(H (4 [50] 3))"
      End
      Begin PaneConfiguration = 7
         NumPanes = 1
         Configuration = "(V (3))"
      End
      Begin PaneConfiguration = 8
         NumPanes = 3
         Configuration = "(H (1[56] 4[18] 2) )"
      End
      Begin PaneConfiguration = 9
         NumPanes = 2
         Configuration = "(H (1 [75] 4))"
      End
      Begin PaneConfiguration = 10
         NumPanes = 2
         Configuration = "(H (1[66] 2) )"
      End
      Begin PaneConfiguration = 11
         NumPanes = 2
         Configuration = "(H (4 [60] 2))"
      End
      Begin PaneConfiguration = 12
         NumPanes = 1
         Configuration = "(H (1) )"
      End
      Begin PaneConfiguration = 13
         NumPanes = 1
         Configuration = "(V (4))"
      End
      Begin PaneConfiguration = 14
         NumPanes = 1
         Configuration = "(V (2))"
      End
      ActivePaneConfig = 0
   End
   Begin DiagramPane = 
      Begin Origin = 
         Top = 0
         Left = 0
      End
      Begin Tables = 
         Begin Table = "igf"
            Begin Extent = 
               Top = 6
               Left = 38
               Bottom = 114
               Right = 227
            End
            DisplayFlags = 280
            TopColumn = 0
         End
         Begin Table = "igfd"
            Begin Extent = 
               Top = 6
               Left = 265
               Bottom = 114
               Right = 470
            End
            DisplayFlags = 280
            TopColumn = 0
         End
      End
   End
   Begin SQLPane = 
   End
   Begin DataPane = 
      Begin ParameterDefaults = ""
      End
   End
   Begin CriteriaPane = 
      Begin ColumnWidths = 11
         Column = 1440
         Alias = 900
         Table = 1170
         Output = 720
         Append = 1400
         NewValue = 1170
         SortType = 1350
         SortOrder = 1410
         GroupBy = 1350
         Filter = 1350
         Or = 1350
         Or = 1350
         Or = 1350
      End
   End
End
' , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'v_implementationguidefile'
GO
EXEC sys.sp_addextendedproperty @name=N'MS_DiagramPaneCount', @value=1 , @level0type=N'SCHEMA',@level0name=N'dbo', @level1type=N'VIEW',@level1name=N'v_implementationguidefile'
GO
