//	This file is part of FeedReader.
//
//	FeedReader is free software: you can redistribute it and/or modify
//	it under the terms of the GNU General Public License as published by
//	the Free Software Foundation, either version 3 of the License, or
//	(at your option) any later version.
//
//	FeedReader is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU General Public License for more details.
//
//	You should have received a copy of the GNU General Public License
//	along with FeedReader.  If not, see <http://www.gnu.org/licenses/>.

public class FeedReader.DataBase : DataBaseReadOnly {

	private static DataBase? m_dataBase = null;

	public static new DataBase writeAccess()
	{
		if(m_dataBase == null)
		{
			m_dataBase = new DataBase();
			if(m_dataBase.uninitialized())
				m_dataBase.init();
		}

		return m_dataBase;
	}

	public static new DataBaseReadOnly readOnly()
	{
		return writeAccess() as DataBaseReadOnly;
	}

	private DataBase(string dbFile = "feedreader-%01i.db".printf(Constants.DB_SCHEMA_VERSION))
	{
		base(dbFile);
	}

	public void checkpoint()
	{
		sqlite_db.wal_checkpoint("");
	}

	public bool resetDB()
	{
		Logger.warning("resetDB");
		executeSQL("DROP TABLE main.feeds");
		executeSQL("DROP TABLE main.categories");
		executeSQL("DROP TABLE main.articles");
		executeSQL("DROP TABLE main.tags");
		executeSQL("DROP TABLE main.fts_table");
		executeSQL("VACUUM");

		string query = "PRAGMA INTEGRITY_CHECK";
		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query, query.length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error(query);
			Logger.error(sqlite_db.errmsg());
		}


		int cols = stmt.column_count ();
		while (stmt.step () == Sqlite.ROW) {
			for (int i = 0; i < cols; i++) {
				if(stmt.column_text(i) != "ok")
				{
					Logger.error("resetting the database failed");
					return false;
				}
			}
		}
		stmt.reset();
		return true;
	}

	public void updateFTS()
	{
		executeSQL("INSERT INTO fts_table(fts_table) VALUES('rebuild')");
	}

	public void springCleaning()
	{
		executeSQL("VACUUM");
		var now = new DateTime.now_local();
		Settings.state().set_int("last-spring-cleaning", (int)now.to_unix());
	}

	public void dropOldArtilces(int weeks)
	{
		var query = new QueryBuilder(QueryType.SELECT, "main.articles");
		query.selectField("articleID");
		query.selectField("feedID");
		query.addCustomCondition("datetime(date, 'unixepoch', 'localtime') <= datetime('now', '-%i days')".printf(weeks*7));
		query.addEqualsCondition("marked", ArticleStatus.UNMARKED.to_string());
		if(FeedServer.get_default().useMaxArticles())
		{
			int syncCount = Settings.general().get_int("max-articles");
			query.addCustomCondition(@"rowid BETWEEN 1 AND (SELECT rowid FROM articles ORDER BY rowid DESC LIMIT 1 OFFSET $syncCount)");
		}
		query.build();
		query.print();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error(sqlite_db.errmsg());
		}

		while (stmt.step () == Sqlite.ROW) {
			delete_article(stmt.column_text(0), stmt.column_text(1));
		}
	}

	private void delete_article(string articleID, string feedID)
	{
		Logger.info("Deleting article \"%s\"".printf(articleID));
		executeSQL("DELETE FROM main.articles WHERE articleID = \"" + articleID + "\"");
		string folder_path = GLib.Environment.get_user_data_dir() + "/feedreader/data/images/%s/%s/".printf(feedID, articleID);
		Utils.remove_directory(folder_path);
	}

	public void dropTag(Tag tag)
	{
		var query = new QueryBuilder(QueryType.DELETE, "main.tags");
		query.addEqualsCondition("tagID", tag.getTagID(), true, true);
		executeSQL(query.build());

		query = new QueryBuilder(QueryType.SELECT, "main.articles");
		query.selectField("tags");
		query.selectField("articleID");
		query.addCustomCondition("instr(tags, \"%s\") > 0".printf(tag.getTagID()));
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(query.get(), query.get().length, out stmt);
		if(ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error(sqlite_db.errmsg());
		}

		while(stmt.step () == Sqlite.ROW)
		{
			string articleID = stmt.column_text(1);
			Gee.List<string> tags = StringUtils.split(stmt.column_text(0), "s", true);
			if(tags.contains(tag.getTagID()))
				tags.remove(tag.getTagID());

			query = new QueryBuilder(QueryType.UPDATE, "main.articles");
			query.updateValuePair("tags", "\"%s\"".printf(StringUtils.join(tags, ",")));
			query.addEqualsCondition("articleID", articleID, true, true);
			executeSQL(query.build());
		}
	}

	public void write_feeds(Gee.List<Feed> feeds)
	{
		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.INSERT_OR_REPLACE, "main.feeds");
		query.insertValuePair("feed_id", "$FEEDID");
		query.insertValuePair("name", "$FEEDNAME");
		query.insertValuePair("url", "$FEEDURL");
		query.insertValuePair("category_id", "$CATID");
		query.insertValuePair("subscribed", "1");
		query.insertValuePair("xmlURL", "$XMLURL");
		query.insertValuePair("iconURL", "$ICONURL");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(query.get(), query.get().length, out stmt);
		if(ec != Sqlite.OK)
		{
			Logger.error("DataBase: write_feeds - " + query.get());
			Logger.error(sqlite_db.errmsg());
		}



		int feedID_pos   = stmt.bind_parameter_index("$FEEDID");
		int feedName_pos = stmt.bind_parameter_index("$FEEDNAME");
		int feedURL_pos  = stmt.bind_parameter_index("$FEEDURL");
		int catID_pos    = stmt.bind_parameter_index("$CATID");
		int xmlURL_pos   = stmt.bind_parameter_index("$XMLURL");
		int iconURL_pos  = stmt.bind_parameter_index("$ICONURL");
		assert (feedID_pos > 0);
		assert (feedName_pos > 0);
		assert (feedURL_pos > 0);
		assert (catID_pos > 0);
		assert (xmlURL_pos > 0);
		assert (iconURL_pos > 0);

		foreach(var feed_item in feeds)
		{
			string catString = "";
			foreach(string category in feed_item.getCatIDs())
			{
				catString += category + ",";
			}

			catString = catString.substring(0, catString.length-1);

			stmt.bind_text(feedID_pos, feed_item.getFeedID());
			stmt.bind_text(feedName_pos, feed_item.getTitle());
			stmt.bind_text(feedURL_pos, feed_item.getURL());
			stmt.bind_text(catID_pos, catString);
			stmt.bind_text(xmlURL_pos, feed_item.getXmlUrl());
			stmt.bind_text(iconURL_pos, feed_item.getIconURL());

			while(stmt.step() == Sqlite.ROW){}
			stmt.reset();
		}

		executeSQL("COMMIT TRANSACTION");
	}

	public void write_tag(Tag tag)
	{
		var list = new Gee.ArrayList<Tag>();
		list.add(tag);
		write_tags(list);
	}

	public void write_tags(Gee.List<Tag> tags)
	{
		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.INSERT_OR_IGNORE, "main.tags");
		query.insertValuePair("tagID", "$TAGID");
		query.insertValuePair("title", "$LABEL");
		query.insertValuePair("\"exists\"", "1");
		query.insertValuePair("color", "$COLOR");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error("DataBase: write_tags - " + query.get());
			Logger.error(sqlite_db.errmsg());
		}

		int tagID_position = stmt.bind_parameter_index("$TAGID");
		int label_position = stmt.bind_parameter_index("$LABEL");
		int color_position = stmt.bind_parameter_index("$COLOR");
		assert (tagID_position > 0);
		assert (label_position > 0);
		assert (color_position > 0);

		foreach(var tag_item in tags)
		{
			//Logger.debug("write_tags: %s %s %i".printf(tag_item.getTagID(), tag_item.getTitle(), tag_item.getColor()));
			stmt.bind_text(tagID_position, tag_item.getTagID());
			stmt.bind_text(label_position, tag_item.getTitle());
			stmt.bind_int (color_position, tag_item.getColor());

			while(stmt.step() == Sqlite.ROW){}
			stmt.reset ();
		}

		executeSQL("COMMIT TRANSACTION");
	}

	public void update_tag(Tag tag)
	{
		var list = new Gee.ArrayList<Tag>();
		list.add(tag);
		update_tags(list);

		if(FeedServer.get_default().tagIDaffectedByNameChange())
		{
			string newID = tag.getTagID().replace(tag.getTitle(), tag.getTitle());
			var query2 = new QueryBuilder(QueryType.UPDATE, "tags");
			query2.updateValuePair("tagID", newID, true);
			query2.addEqualsCondition("tagID", tag.getTagID(), true, true);
			executeSQL(query2.build());
			query2.print();

			var query3 = new QueryBuilder(QueryType.UPDATE, "articles");
			query3.updateValuePair("tags", "replace(tags, '%s', '%s')".printf(tag.getTagID(), newID));
			query3.addCustomCondition("instr(tags, '%s')".printf(tag.getTagID()));
			executeSQL(query3.build());
			query3.print();
		}
	}

	public void update_tags(Gee.List<Tag> tags)
	{
		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.UPDATE, "main.tags");
		query.updateValuePair("title", "$TITLE");
		query.updateValuePair("\"exists\"", "1");
		query.addEqualsCondition("tagID", "$TAGID");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error("DataBase: update_tags - " + query.get());
			Logger.error(sqlite_db.errmsg());
		}

		int title_position = stmt.bind_parameter_index("$TITLE");
		int tagID_position = stmt.bind_parameter_index("$TAGID");
		assert (title_position > 0);
		assert (tagID_position > 0);

		foreach(var tag_item in tags)
		{
			stmt.bind_text(title_position, tag_item.getTitle());
			stmt.bind_text(tagID_position, tag_item.getTagID());
			while (stmt.step () == Sqlite.ROW) {}
			stmt.reset ();
		}

		executeSQL("COMMIT TRANSACTION");
	}


	public void write_categories(Gee.List<Category> categories)
	{
		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.INSERT_OR_REPLACE, "main.categories");
		query.insertValuePair("categorieID", "$CATID");
		query.insertValuePair("title", "$FEEDNAME");
		query.insertValuePair("orderID", "$ORDERID");
		query.insertValuePair("\"exists\"", "1");
		query.insertValuePair("Parent", "$PARENT");
		query.insertValuePair("Level", "$LEVEL");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error("DataBase: write_categories - " + query.get());
			Logger.error(sqlite_db.errmsg());
		}


		int catID_position       = stmt.bind_parameter_index("$CATID");
		int feedName_position    = stmt.bind_parameter_index("$FEEDNAME");
		int orderID_position     = stmt.bind_parameter_index("$ORDERID");
		int parent_position      = stmt.bind_parameter_index("$PARENT");
		int level_position       = stmt.bind_parameter_index("$LEVEL");
		assert (catID_position > 0);
		assert (feedName_position > 0);
		assert (orderID_position > 0);
		assert (parent_position > 0);
		assert (level_position > 0);

		foreach(var cat_item in categories)
		{
			stmt.bind_text(catID_position, cat_item.getCatID());
			stmt.bind_text(feedName_position, cat_item.getTitle());
			stmt.bind_int (orderID_position, cat_item.getOrderID());
			stmt.bind_text(parent_position, cat_item.getParent());
			stmt.bind_int (level_position, cat_item.getLevel());

			while (stmt.step () == Sqlite.ROW) {}
			stmt.reset ();
		}

		executeSQL("COMMIT TRANSACTION");
	}

	public void updateArticlesByID(Gee.List<string> ids, string field)
	{
		// first reset all articles
		var reset_query = new QueryBuilder(QueryType.UPDATE, "main.articles");
		if(field == "unread")
			reset_query.updateValuePair(field, ArticleStatus.READ.to_string());
		else if(field == "marked")
			reset_query.updateValuePair(field, ArticleStatus.UNMARKED.to_string());
		executeSQL(reset_query.build());


		executeSQL("BEGIN TRANSACTION");

		// then reapply states of the synced articles
		var update_query = new QueryBuilder(QueryType.UPDATE, "main.articles");

		if(field == "unread")
			update_query.updateValuePair(field, ArticleStatus.UNREAD.to_string());
		else if(field == "marked")
			update_query.updateValuePair(field, ArticleStatus.MARKED.to_string());

		update_query.addEqualsCondition("articleID", "$ARTICLEID");
		update_query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (update_query.get(), update_query.get().length, out stmt);

		if (ec != Sqlite.OK)
		{
			Logger.error(update_query.get());
			Logger.error("updateArticlesByID: " + sqlite_db.errmsg());
		}

		int articleID_position = stmt.bind_parameter_index("$ARTICLEID");
		assert (articleID_position > 0);


		foreach(string id in ids)
		{
			stmt.bind_text(articleID_position, id);
			while(stmt.step() != Sqlite.DONE){}
			stmt.reset();
		}

		executeSQL("COMMIT TRANSACTION");
	}

	public void writeContent(Article article)
	{
		var update_query = new QueryBuilder(QueryType.UPDATE, "main.articles");
		update_query.updateValuePair("html", "$HTML");
		update_query.updateValuePair("preview", "$PREVIEW");
		update_query.updateValuePair("contentFetched", "1");
		update_query.addEqualsCondition("articleID", article.getArticleID(), true, true);
		update_query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(update_query.get(), update_query.get().length, out stmt);

		if(ec != Sqlite.OK)
		{
			Logger.error(update_query.get());
			Logger.error("writeContent: " + sqlite_db.errmsg());
		}

		int html_position = stmt.bind_parameter_index("$HTML");
		int preview_position = stmt.bind_parameter_index("$PREVIEW");
		assert (html_position > 0);
		assert (preview_position > 0);


		stmt.bind_text(html_position, article.getHTML());
		stmt.bind_text(preview_position, article.getPreview());

		while(stmt.step() != Sqlite.DONE){}
		stmt.reset();
	}

	public void update_article(Article article)
	{
		var list = new Gee.ArrayList<Article>();
		list.add(article);
		update_articles(list);
	}

	// public void update_article(Article article, string field, int field_value)
	// {
	// 	var query = new QueryBuilder(QueryType.UPDATE, "main.articles");
	// 	query.updateValuePair(field, field_value.to_string());
	// 	query.addEqualsCondition("articleID", article.getArticleID(), true, true);
	// 	executeSQL(query.build());
	// }

	public void update_articles(Gee.List<Article> articles)
	{
		executeSQL("BEGIN TRANSACTION");

		var update_query = new QueryBuilder(QueryType.UPDATE, "main.articles");
		update_query.updateValuePair("unread", "$UNREAD");
		update_query.updateValuePair("marked", "$MARKED");
		update_query.updateValuePair("tags", "$TAGS");
		update_query.updateValuePair("lastModified", "$LASTMODIFIED");
		update_query.addEqualsCondition("articleID", "$ARTICLEID", true, false);
		update_query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(update_query.get(), update_query.get().length, out stmt);

		if(ec != Sqlite.OK)
		{
			Logger.error(update_query.get());
			Logger.error("update_articles: " + sqlite_db.errmsg());
		}

		int unread_position = stmt.bind_parameter_index("$UNREAD");
		int marked_position = stmt.bind_parameter_index("$MARKED");
		int tags_position = stmt.bind_parameter_index("$TAGS");
		int modified_position = stmt.bind_parameter_index("$LASTMODIFIED");
		int articleID_position = stmt.bind_parameter_index("$ARTICLEID");
		assert (unread_position > 0);
		assert (marked_position > 0);
		assert (tags_position > 0);
		assert (modified_position > 0);
		assert (articleID_position > 0);


		foreach(Article a in articles)
		{
			var unread = ActionCache.get_default().checkRead(a);
			var marked = ActionCache.get_default().checkStarred(a.getArticleID(), a.getMarked());

			if(unread != ArticleStatus.READ && unread != ArticleStatus.UNREAD)
				Logger.warning(@"DataBase.update_articles: writing invalid unread status $unread for article " + a.getArticleID());

			if(marked != ArticleStatus.MARKED && marked != ArticleStatus.UNMARKED)
				Logger.warning(@"DataBase.update_articles: writing invalid marked status $marked for article " + a.getArticleID());

			stmt.bind_int (unread_position, unread);
			stmt.bind_int (marked_position, marked);
			stmt.bind_text(tags_position, a.getTagString());
			stmt.bind_int (modified_position, a.getLastModified());
			stmt.bind_text(articleID_position, a.getArticleID());

			while(stmt.step() != Sqlite.DONE){}
			stmt.reset();
		}

		executeSQL("COMMIT TRANSACTION");
	}


	public void write_articles(Gee.List<Article> articles)
	{
		Utils.generatePreviews(articles);
		Utils.checkHTML(articles);

		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.INSERT_OR_IGNORE, "main.articles");
		query.insertValuePair("articleID", "$ARTICLEID");
		query.insertValuePair("feedID", "$FEEDID");
		query.insertValuePair("title", "$TITLE");
		query.insertValuePair("author", "$AUTHOR");
		query.insertValuePair("url", "$URL");
		query.insertValuePair("html", "$HTML");
		query.insertValuePair("preview", "$PREVIEW");
		query.insertValuePair("unread", "$UNREAD");
		query.insertValuePair("marked", "$MARKED");
		query.insertValuePair("tags", "$TAGS");
		query.insertValuePair("date", "$DATE");
		query.insertValuePair("guidHash", "$GUIDHASH");
		query.insertValuePair("lastModified", "$LASTMODIFIED");
		query.insertValuePair("media", "$MEDIA");
		query.insertValuePair("contentFetched", "0");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(query.get(), query.get().length, out stmt);

		if (ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error("write_articles: " + sqlite_db.errmsg());
		}



		int articleID_position = stmt.bind_parameter_index("$ARTICLEID");
		int feedID_position = stmt.bind_parameter_index("$FEEDID");
		int url_position = stmt.bind_parameter_index("$URL");
		int unread_position = stmt.bind_parameter_index("$UNREAD");
		int marked_position = stmt.bind_parameter_index("$MARKED");
		int tags_position = stmt.bind_parameter_index("$TAGS");
		int title_position = stmt.bind_parameter_index("$TITLE");
		int html_position = stmt.bind_parameter_index("$HTML");
		int preview_position = stmt.bind_parameter_index("$PREVIEW");
		int author_position = stmt.bind_parameter_index("$AUTHOR");
		int date_position = stmt.bind_parameter_index("$DATE");
		int guidHash_position = stmt.bind_parameter_index("$GUIDHASH");
		int modified_position = stmt.bind_parameter_index("$LASTMODIFIED");
		int media_position = stmt.bind_parameter_index("$MEDIA");

		assert (articleID_position > 0);
		assert (feedID_position > 0);
		assert (url_position > 0);
		assert (unread_position > 0);
		assert (marked_position > 0);
		assert (tags_position > 0);
		assert (title_position > 0);
		assert (html_position > 0);
		assert (preview_position > 0);
		assert (author_position > 0);
		assert (date_position > 0);
		assert (guidHash_position > 0);
		assert (modified_position > 0);
		assert (media_position > 0);

		foreach(var article in articles)
		{
			// if article time is in the future
			var now = new GLib.DateTime.now_local();
			if(article.getDate().compare(now) == 1)
				article.SetDate(now);

				int weeks = 0;
				switch(Settings.general().get_enum("drop-articles-after"))
				{
					case DropArticles.ONE_WEEK:
						weeks = 1;
						break;
					case DropArticles.ONE_MONTH:
						weeks = 4;
						break;
					case DropArticles.SIX_MONTHS:
						weeks = 24;
						break;
				}

				if(Settings.general().get_enum("drop-articles-after") != DropArticles.NEVER
				&& article.getDate().compare(now.add_weeks(-weeks)) == -1)
					continue;


			stmt.bind_text(articleID_position, article.getArticleID());
			stmt.bind_text(feedID_position, article.getFeedID());
			stmt.bind_text(url_position, article.getURL());
			stmt.bind_int (unread_position, article.getUnread());
			stmt.bind_int (marked_position, article.getMarked());
			stmt.bind_text(tags_position, article.getTagString());
			stmt.bind_text(title_position, Utils.UTF8fix(article.getTitle()));
			stmt.bind_text(html_position, article.getHTML());
			stmt.bind_text(preview_position, Utils.UTF8fix(article.getPreview(), true));
			stmt.bind_text(author_position, article.getAuthor());
			stmt.bind_int64(date_position, article.getDate().to_unix());
			stmt.bind_text(guidHash_position, article.getHash());
			stmt.bind_int (modified_position, article.getLastModified());
			stmt.bind_text(media_position, article.getMediaString());

			while(stmt.step() != Sqlite.DONE){}
			stmt.reset();
		}

		executeSQL("COMMIT TRANSACTION");
	}

	public void markCategorieRead(string catID)
	{
		var query = new QueryBuilder(QueryType.UPDATE, "main.articles");
		query.updateValuePair("unread", ArticleStatus.READ.to_string());
		query.addRangeConditionString("feedID", getFeedIDofCategorie(catID));
		executeSQL(query.build());
	}

	public void markFeedRead(string feedID)
	{
		var query = new QueryBuilder(QueryType.UPDATE, "main.articles");
		query.updateValuePair("unread", ArticleStatus.READ.to_string());
		query.addEqualsCondition("feedID", feedID, true, true);
		executeSQL(query.build());
	}

	public void markAllRead()
	{
		var query1 = new QueryBuilder(QueryType.UPDATE, "main.articles");
		query1.updateValuePair("unread", ArticleStatus.READ.to_string());
		executeSQL(query1.build());
	}

	public void reset_subscribed_flag()
	{
		executeSQL("UPDATE main.feeds SET \"subscribed\" = 0");
	}

	public void reset_exists_tag()
	{
		executeSQL("UPDATE main.tags SET \"exists\" = 0");
	}

	public void reset_exists_flag()
	{
		executeSQL("UPDATE main.categories SET \"exists\" = 0");
	}

	public void delete_unsubscribed_feeds()
	{
		Logger.warning("DataBase: Deleting unsubscribed feeds");
		executeSQL("DELETE FROM main.feeds WHERE \"subscribed\" = 0");
	}


	public void delete_nonexisting_categories()
	{
		Logger.warning("DataBase: Deleting nonexisting categories");
		executeSQL("DELETE FROM main.categories WHERE \"exists\" = 0");
	}

	public void delete_nonexisting_tags()
	{
		Logger.warning("DataBase: Deleting nonexisting tags");
		executeSQL("DELETE FROM main.tags WHERE \"exists\" = 0");
	}

	public void delete_articles_without_feed()
	{
		Logger.warning("DataBase: Deleting articles without feed");
		var query = new QueryBuilder(QueryType.SELECT, "main.feeds");
		query.selectField("feed_id");
		query.addEqualsCondition("subscribed", "0", true, false);
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if(ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error("DataBase: delete_articles_without_feed: %d: %s".printf(sqlite_db.errcode(), sqlite_db.errmsg()));
		}

		while(stmt.step () == Sqlite.ROW)
		{
			delete_articles(stmt.column_text(0));
		}
	}

	public void delete_articles(string feedID)
	{
		Logger.warning("DataBase: Deleting all articles of feed \"%s\"".printf(feedID));
		executeSQL("DELETE FROM main.articles WHERE feedID = \"" + feedID + "\"");
		string folder_path = GLib.Environment.get_user_data_dir() + "/feedreader/data/images/%s/".printf(feedID);
		Utils.remove_directory(folder_path);
	}

	public void delete_category(string catID)
	{
		executeSQL("DELETE FROM main.categories WHERE categorieID = \"" + catID + "\"");

		if(FeedServer.get_default().supportMultiCategoriesPerFeed())
		{
			var query = new QueryBuilder(QueryType.SELECT, "feeds");
			query.selectField("feed_id, category_id");
			query.addCustomCondition("instr(category_id, \"%s\") > 0".printf(catID));
			query.build();

			Sqlite.Statement stmt;
			int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
			if (ec != Sqlite.OK)
			{
				Logger.error(query.get());
				Logger.error("delete_articles: " + sqlite_db.errmsg());
			}

			while(stmt.step () == Sqlite.ROW)
			{
				string feedID = stmt.column_text(0);
				string catIDs = stmt.column_text(0).replace(catID + ",", "");

				executeSQL("UPDATE main.feeds set category_id = \"" + catIDs + "\" WHERE feed_id = \"" + feedID + "\"");
			}
		}
		else
		{
			executeSQL("UPDATE main.feeds set category_id = \"%s\" WHERE category_id = \"%s\"".printf(FeedServer.get_default().uncategorizedID(), catID));

			if(FeedServer.get_default().supportMultiLevelCategories())
			{
				executeSQL("UPDATE main.categories set Parent = \"-2\" WHERE categorieID = \"" + catID + "\"");
			}
		}
	}

	public void rename_category(string catID, string newName)
	{

		if(FeedServer.get_default().tagIDaffectedByNameChange())
		{
			var cat = read_category(catID);
			string newID = catID.replace(cat.getTitle(), newName);
			var query2 = new QueryBuilder(QueryType.UPDATE, "categories");
			query2.updateValuePair("categorieID", newID, true);
			query2.addEqualsCondition("categorieID", catID, true, true);
			executeSQL(query2.build());
			query2.print();

			var query3 = new QueryBuilder(QueryType.UPDATE, "feeds");
			query3.updateValuePair("category_id", "replace(category_id, '%s', '%s')".printf(catID, newID));
			query3.addCustomCondition("instr(category_id, '%s')".printf(catID));
			executeSQL(query3.build());
			query3.print();

			var query = new QueryBuilder(QueryType.UPDATE, "categories");
			query.updateValuePair("title", newName, true);
			query.addEqualsCondition("categorieID", newID, true, true);
			executeSQL(query.build());
		}
		else
		{
			var query = new QueryBuilder(QueryType.UPDATE, "categories");
			query.updateValuePair("title", newName, true);
			query.addEqualsCondition("categorieID", catID, true, true);
			executeSQL(query.build());
		}


	}

	public void move_category(string catID, string newParentID)
	{
		var parent = read_category(newParentID);
		var query = new QueryBuilder(QueryType.UPDATE, "categories");
		query.updateValuePair("Parent", newParentID);
		query.updateValuePair("Level", "%i".printf(parent.getLevel()+1));
		query.addEqualsCondition("categorieID", catID);
		executeSQL(query.build());
	}

	public void rename_feed(string feedID, string newName)
	{
		var query = new QueryBuilder(QueryType.UPDATE, "feeds");
		query.updateValuePair("name", newName, true);
		query.addEqualsCondition("feed_id", feedID, true, true);
		executeSQL(query.build());
	}

	public void move_feed(string feedID, string currentCatID, string? newCatID = null)
	{
		var Feed = read_feed(feedID);
		var categories = Feed.getCatIDs();
		categories.remove(currentCatID);

		if(newCatID != null)
			categories.add(newCatID);

		string catString = StringUtils.join(categories, ",");

		var query = new QueryBuilder(QueryType.UPDATE, "feeds");
		query.updateValuePair("category_id", catString, true);
		query.addEqualsCondition("feed_id", feedID, true, true);
		executeSQL(query.build());
	}

	public void removeCatFromFeed(string feedID, string catID)
	{
		var feed = read_feed(feedID);
		var query = new QueryBuilder(QueryType.UPDATE, "feeds");
		query.updateValuePair("category_id", feed.getCatString().replace(catID + ",", ""), true);
		query.addEqualsCondition("feed_id", feedID, true, true);
		executeSQL(query.build());
	}

	public void delete_feed(string feedID)
	{
		executeSQL("DELETE FROM feeds WHERE feed_id = \"%s\"".printf(feedID));
		delete_articles(feedID);
	}

	public void addCachedAction(CachedActions action, string id, string? argument = "")
	{
		executeSQL("BEGIN TRANSACTION");

		var query = new QueryBuilder(QueryType.INSERT_OR_IGNORE, "main.CachedActions");
		query.insertValuePair("action", "$ACTION");
		query.insertValuePair("id", "$ID");
		query.insertValuePair("argument", "$ARGUMENT");
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2 (query.get(), query.get().length, out stmt);
		if (ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error("addCachedAction: " + sqlite_db.errmsg());
		}


		int action_position = stmt.bind_parameter_index("$ACTION");
		int id_position = stmt.bind_parameter_index("$ID");
		int argument_position = stmt.bind_parameter_index("$ARGUMENT");
		assert (action_position > 0);
		assert (id_position > 0);
		assert (argument_position > 0);

		stmt.bind_int (action_position, action);
		stmt.bind_text(id_position, id);
		stmt.bind_text(argument_position, argument);

		while (stmt.step () == Sqlite.ROW) {}
		stmt.reset ();

		executeSQL("COMMIT TRANSACTION");
	}


	public Gee.List<CachedAction> readCachedActions()
	{
		Gee.ArrayList<CachedAction> tmp = new Gee.ArrayList<CachedAction>();

		var query = new QueryBuilder(QueryType.SELECT, "CachedActions");
		query.selectField("*");
		query.build();
		query.print();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(query.get(), query.get().length, out stmt);
		if(ec != Sqlite.OK)
		{
			Logger.error(query.get());
			Logger.error("readCachedActions: " + sqlite_db.errmsg());
		}

		while(stmt.step () == Sqlite.ROW)
		{
			var action = new CachedAction((CachedActions)stmt.column_int(0), stmt.column_text(1), stmt.column_text(2));
			action.print();
			tmp.add(action);
		}

		return tmp;
	}

	public void resetCachedActions()
	{
		Logger.warning("resetCachedActions");
		executeSQL("DELETE FROM CachedActions");
	}

	public bool cachedActionNecessary(CachedAction action)
	{
		var query = new QueryBuilder(QueryType.SELECT, "CachedActions");
		query.selectField("count(*)");
		query.addEqualsCondition("argument", action.getArgument(), true, true);
		query.addEqualsCondition("id", action.getID(), true, true);
		query.addEqualsCondition("action", "%i".printf(action.opposite()));
		query.build();

		Sqlite.Statement stmt;
		int ec = sqlite_db.prepare_v2(query.get(), query.get().length, out stmt);
		if(ec != Sqlite.OK)
		{
			Logger.error("cachedActionNecessary - %s".printf(sqlite_db.errmsg()));
			Logger.error(query.get());
		}

		while(stmt.step () == Sqlite.ROW)
		{
			if(stmt.column_int(0) > 0)
				return false;
		}

		return true;
	}

	public void deleteOppositeCachedAction(CachedAction action)
	{
		var query = new QueryBuilder(QueryType.DELETE, "CachedActions");
		query.addEqualsCondition("argument", action.getArgument(), true, true);
		query.addEqualsCondition("id", action.getID(), true, true);
		query.addEqualsCondition("action", "%i".printf(action.opposite()));
		executeSQL(query.build());
		query.print();
	}

}
