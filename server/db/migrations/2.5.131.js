exports.up = async knex => {
  const row = await knex('settings').where('key', 'logoUrl').first()
  if (row && row.value) {
    const current = (row.value.v !== undefined) ? row.value.v : row.value
    if (current === 'https://static.requarks.io/logo/wikijs-butterfly.svg') {
      await knex('settings').where('key', 'logoUrl').update({
        value: JSON.stringify({ v: '/_assets/svg/logo-wikijs-butterfly.svg' })
      })
    }
  }
}

exports.down = async knex => {
  const row = await knex('settings').where('key', 'logoUrl').first()
  if (row && row.value) {
    const current = (row.value.v !== undefined) ? row.value.v : row.value
    if (current === '/_assets/svg/logo-wikijs-butterfly.svg') {
      await knex('settings').where('key', 'logoUrl').update({
        value: JSON.stringify({ v: 'https://static.requarks.io/logo/wikijs-butterfly.svg' })
      })
    }
  }
}
