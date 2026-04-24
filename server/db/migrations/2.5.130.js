exports.up = async knex => {
  await knex.schema.table('pages', table => {
    // Speeds up getPageFromDb, movePage, comment lookups — all filter by (localeCode, path)
    table.index(['localeCode', 'path'], 'pages_localeCode_path')
    // Speeds up pageHistory join and UserProfile.pagesTotal
    table.index(['creatorId'], 'pages_creatorId')
  })

  await knex.schema.table('pageHistory', table => {
    // Speeds up getHistory and getVersion — both filter by pageId
    table.index(['pageId'], 'pageHistory_pageId')
  })

  await knex.schema.table('pageTree', table => {
    // Speeds up updatePage title sync — WHERE pageId = ?
    table.index(['pageId'], 'pageTree_pageId')
  })
}

exports.down = async knex => {
  await knex.schema.table('pages', table => {
    table.dropIndex([], 'pages_localeCode_path')
    table.dropIndex([], 'pages_creatorId')
  })

  await knex.schema.table('pageHistory', table => {
    table.dropIndex([], 'pageHistory_pageId')
  })

  await knex.schema.table('pageTree', table => {
    table.dropIndex([], 'pageTree_pageId')
  })
}
