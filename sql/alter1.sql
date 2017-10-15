alter table entry add column keyword_length int unsigned not null default 0;
update entry set keyword_length = CHARACTER_LENGTH(keyword);
alter table entry add index idx_keyword_length_keyword (keyword_length, keyword);

