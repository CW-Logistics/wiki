exports.up = async knex => {
  await knex.schema.table('pageTree', table => {
    // Speeds up path lookup used to resolve current page's parent + ancestors on every page load
    table.index(['path', 'localeCode'], 'pageTree_path_localeCode')
    // Speeds up fetching children/siblings by parent
    table.index(['parent', 'localeCode'], 'pageTree_parent_localeCode')
  })
}

exports.down = async knex => {
  await knex.schema.table('pageTree', table => {
    table.dropIndex([], 'pageTree_path_localeCode')
    table.dropIndex([], 'pageTree_parent_localeCode')
  })
}
