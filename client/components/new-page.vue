<template lang='pug'>
  v-app
    .newpage
      .newpage-content
        img.animated.fadeIn(src='/_assets/svg/icon-delete-file.svg', alt='Not Found')
        .headline {{ $t('newpage.title') }}
        .subtitle-1.mt-3 {{ $t('newpage.subtitle') }}
        v-btn.mt-5(v-if='canWrite === `true`', :href='`/e/` + locale + `/` + path', x-large)
          v-icon(left) mdi-plus
          span {{ $t('newpage.create') }}
        v-btn.mt-5(color='purple lighten-3', href='javascript:window.history.go(-1);', outlined)
          v-icon(left) mdi-arrow-left
          span {{ $t('newpage.goback') }}
        .newpage-tree(v-if='treeItems.length > 0')
          .newpage-tree-title Contents of /{{ path }}
          .newpage-tree-list
            template(v-for='item in treeItems')
              .newpage-tree-item(v-if='item.isFolder')
                a(:href='`/` + locale + `/` + item.path')
                  v-icon(small, color='amber darken-2') mdi-folder
                  |  {{ item.title }}
                template(v-if='item.children && item.children.length > 0')
                  .newpage-tree-item.newpage-tree-item--child(v-for='child in item.children', :key='child.id')
                    a(:href='`/` + locale + `/` + child.path')
                      v-icon(small, :color='child.isFolder ? `amber darken-2` : `blue-grey lighten-1`') {{ child.isFolder ? `mdi-folder` : `mdi-file-document-outline` }}
                      |  {{ child.title }}
              .newpage-tree-item(v-else)
                a(:href='`/` + locale + `/` + item.path')
                  v-icon(small, color='blue-grey lighten-1') mdi-file-document-outline
                  |  {{ item.title }}
</template>

<script>
import gql from 'graphql-tag'

const TREE_QUERY = gql`
  query ($parent: Int, $path: String, $locale: String!) {
    pages {
      tree(parent: $parent, path: $path, mode: ALL, locale: $locale) {
        id
        path
        title
        isFolder
        pageId
        parent
      }
    }
  }
`

export default {
  props: {
    locale: {
      type: String,
      default: 'en'
    },
    path: {
      type: String,
      default: 'home'
    },
    canWrite: {
      type: String,
      default: 'false'
    }
  },
  data() {
    return {
      treeItems: []
    }
  },
  async mounted() {
    try {
      const resp = await this.$apollo.query({
        query: TREE_QUERY,
        variables: { path: this.path, locale: this.locale },
        fetchPolicy: 'network-only'
      })
      const level1 = (resp.data.pages.tree || [])
      if (level1.length === 0) { return }

      const folders = level1.filter(i => i.isFolder)
      const childResults = await Promise.all(
        folders.map(f =>
          this.$apollo.query({
            query: TREE_QUERY,
            variables: { parent: f.id, locale: this.locale },
            fetchPolicy: 'network-only'
          }).then(r => r.data.pages.tree || [])
        )
      )

      this.treeItems = level1.map(item => {
        if (!item.isFolder) { return item }
        const idx = folders.indexOf(item)
        return { ...item, children: childResults[idx] }
      })
    } catch (e) {
      // Silently ignore — placeholder listing is best-effort
    }
  }
}
</script>

<style lang='scss'>
.newpage {
  display: flex;
  justify-content: center;
  padding: 32px 16px;

  &-content {
    display: flex;
    flex-direction: column;
    align-items: center;
    max-width: 640px;
    width: 100%;
  }

  &-tree {
    margin-top: 40px;
    width: 100%;
    text-align: left;

    &-title {
      font-size: 0.95rem;
      font-weight: 500;
      color: rgba(0,0,0,.54);
      margin-bottom: 12px;
      font-family: monospace;
    }

    &-list {
      border-left: 2px solid rgba(0,0,0,.1);
      padding-left: 12px;
    }

    &-item {
      padding: 3px 0;
      line-height: 1.5;

      a {
        color: inherit;
        text-decoration: none;
        display: inline-flex;
        align-items: center;
        gap: 4px;

        &:hover {
          text-decoration: underline;
        }
      }

      &--child {
        margin-left: 20px;
      }
    }
  }
}
</style>
