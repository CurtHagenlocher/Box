section Box;

client_application = Expression.Evaluate(Text.FromBinary(Extension.Contents("client_application")));
windowWidth = 1200;
windowHeight = 1000;

TokenMethod = (code, grant_type) =>
    let
        Response = Web.Contents("https://app.box.com/api/oauth2/token", [
            Content = Text.ToBinary(Uri.BuildQueryString([
                client_id = client_application[ClientId],
                client_secret = client_application[ClientSecret],
                grant_type = grant_type,
                code = code,
                redirect_uri = client_application[CallbackUrl]
            ])),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded"]
        ]),
        Parts = Json.Document(Response)
    in
        Parts;

StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = "https://app.box.com/api/oauth2/authorize?" & Uri.BuildQueryString([
            client_id = client_application[ClientId],
            response_type = "code",
            state = state,
            redirect_uri = client_application[CallbackUrl]])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = client_application[CallbackUrl],
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = null
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(Parts[code], "authorization_code");

Refresh = (resourceUrl, refresh_token) => TokenMethod(refresh_token, "refresh_token");

Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if (firstRow = null) then
            Table.FromRows({})
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

GetOneDirectory = (dirId, dirPath) =>
    let
        source = Web.Contents("https://api.box.com/2.0/folders/" & dirId),
        json = Json.Document(source),
        contents = json[item_collection][entries],
        table = Table.FromList(contents, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.Buffer(Table.ExpandRecordColumn(table, "Column1", {"type", "id", "sequence_id", "etag", "name", "sha1"}, {"type", "id", "sequence_id", "etag", "name", "sha1"})),
        added = Table.AddColumn(expanded, "path", each dirPath & "/" & [name])
    in
        added;

GetDirectory = (dirId, dirPath) => Table.GenerateByPage((previous) =>
    let
        dirlist = if previous = null then {} else Value.Metadata(previous)[dirs],
        nextdir = if previous = null then {dirId, dirPath} else List.First(dirlist),
        directory = if nextdir = null then null else GetOneDirectory(nextdir{0}, nextdir{1}),
        moredirs = if directory = null then {} else List.Transform(Table.ToRecords(Table.SelectRows(directory, each [type] = "folder")), each {[id], dirPath & "/" & [name]}),
        files = if directory = null then null else Table.SelectRows(directory, each [type] <> "folder"),
        newlist = List.Skip(dirlist, 1) & moredirs
    in
        files meta [dirs=newlist]);

GetDirectoryAndFiles = (dirId, dirPath) =>
    let
        files = GetDirectory(dirId, dirPath),
        withContent = Table.AddColumn(files, "Content", each Web.Contents("https://api.box.com/2.0/files/" & [id] & "/content")),
        reordered = Table.ReorderColumns(withContent,{"Content", "path", "type", "id", "sequence_id", "etag", "name", "sha1"})
    in
        reordered;

[DataSource.Kind = "Box"]
shared Box.Contents = () => GetDirectoryAndFiles("0", "");

Box = [
    Authentication=[OAuth=[StartLogin=StartLogin, FinishLogin=FinishLogin, Refresh=Refresh]]
];
