#загружаем пакеты и данные
library(dada2); packageVersion("dada2")
library(vegan)
library("ggplot2"); packageVersion("ggplot2")
library("ape")
library(phyloseq); packageVersion("phyloseq")
library(Biostrings); packageVersion("Biostrings")
vignette("phyloseq-basics")

path <- "~/storage/vologda/vologda/"
list.files(path)

#################################################################################################################
#пройдемся по пунктам пайплайна DADA2 (https://benjjneb.github.io/dada2/tutorial.html)
#################################################################################################################

#читаем имена файлов fastq и выполняем некоторые манипуляции со строками, чтобы получить совпадающие списки прямого и обратного файлов fastq.
fnFs <- sort(list.files(path, pattern="_R1_001.fastq", full.names = TRUE))
fnRs <- sort(list.files(path, pattern="_R2_001.fastq", full.names = TRUE))
#получаем имена семплов
sample.names <- sapply(strsplit(basename(fnFs), "_"), `[`, 1)

#начнем с визуализации профилей качества форвард-ридов
plotQualityProfile(fnFs[1:2])
#визуализируем реверсы
plotQualityProfile(fnRs[1:2])

#назначим имена файлов для отфильтрованных файлов fastq.gz
filtFs <- file.path(path, "filtered", paste0(sample.names, "_F_filt.fastq.gz"))
filtRs <- file.path(path, "filtered", paste0(sample.names, "_R_filt.fastq.gz"))
names(filtFs) <- sample.names
names(filtRs) <- sample.names

#обрезаем и фильтруем, определяем truncLen исходя из визуализации качества ридов и некоторых личных предпочтений к обработке данных
out <- filterAndTrim(fnFs, filtFs, fnRs, filtRs, truncLen=c(220,160),
                     maxN=0, maxEE=c(2,2), truncQ=2, rm.phix=TRUE,
                     compress=TRUE, multithread=TRUE) # On Windows set multithread=FALSE
#проверка, что все отработало верно
head(out)

#Алгоритм DADA2 использует модель параметрической ошибки(err), и каждый набор данных ампликона имеет свой набор ошибок. 
#learnErrorsМетод узнает эту модель ошибки из данных, с помощью переменного оценивания частоты ошибок и 
#вывода образца композиции, пока они не сходятся на совместно последовательное решение. 
#Алгоритм начинается с первоначального предположения, для которого используются максимально возможные коэффициенты ошибок в этих данных 
#(коэффициенты ошибок, если верна только наиболее распространенная последовательность, а все остальные ошибки).
errF <- learnErrors(filtFs, multithread=TRUE)
errR <- learnErrors(filtRs, multithread=TRUE)
#в качестве проверки работоспособности визуализируем оценочные коэффициенты ошибок:
plotErrors(errF, nominalQ=TRUE)

#вывод образцов с высоким разрешением по данным об ампликонах Illumina
dadaFs <- dada(filtFs, err=errF, multithread=TRUE)
dadaRs <- dada(filtRs, err=errR, multithread=TRUE)
#просматриваем возвращенный dada-class объект:
dadaFs[[1]]

#объединяем прямое и обратное чтение вместе
mergers <- mergePairs(dadaFs, filtFs, dadaRs, filtRs, verbose=TRUE)
#проверяем наш дата-фрейм просмотрев первые образцы
head(mergers[[1]])

#строим таблицу вариантов последовательности ампликонов (ASV), версию таблицы OTU с более высоким разрешением, созданную традиционными методами
seqtab <- makeSequenceTable(mergers)
#проверяем размерность
dim(seqtab)
#проверяем распределение длинн последовательностей
table(nchar(getSequences(seqtab)))

#удаляем химеры
seqtab.nochim <- removeBimeraDenovo(seqtab, method="consensus", multithread=TRUE, verbose=TRUE)
#еще пара проверок того, что все работает верно
dim(seqtab.nochim)
sum(seqtab.nochim)/sum(seqtab)

#смотрим конечные результаты числа прочтений в образцах, оценивая, не было ли сильных потерь на каком-либо из этапов:
getN <- function(x) sum(getUniques(x))
track <- cbind(out, sapply(dadaFs, getN), sapply(dadaRs, getN), sapply(mergers, getN), rowSums(seqtab.nochim))
colnames(track) <- c("input", "filtered", "denoisedF", "denoisedR", "merged", "nonchim")
rownames(track) <- sample.names
head(track)
#запишем данные в таблицу
write.csv(track, "track.csv")

#назначаем таксономию вариантам последовательности 
#Пакет DADA2 предоставляет для этой цели встроенную реализацию метода наивного байесовского классификатора. 
#assignTaxonomyФункция принимает в качестве входных данных набор последовательностей, 
#которые будут классифицированы и обучающий набор эталонных последовательностей известной систематики и 
#выводит таксономические значения, по меньшей мере minBoot.
taxa <- assignTaxonomy(seqtab.nochim, "~/storage/tax/silva_nr_v132_train_set.fa.gz", multithread=TRUE)
taxa <- addSpecies(taxa, "~/storage/tax/silva_species_assignment_v132.fa.gz")
taxa.print <- taxa 
rownames(taxa.print) <- NULL
#проверка
head(taxa.print)

##############################################################################
#работа с метаданными, создаем ps-объект
##############################################################################
map <- read.csv2("~/storage/vologda/vologda/map_vologda_full.csv", sep = ';', row.names = 1)
mdat <- map[order(rownames(map)), ]
seqtab2 <- seqtab.nochim[order(rownames(seqtab.nochim)), ]

#обязательно проверяем соответствие названий в карте и таблице с таксономией
View(cbind(as.vector(rownames(seqtab2)), as.vector(rownames(mdat))))

#собираем ps-объкт проверяя на каждом шаге, в данном эксперименте было принято решение убрать все образцы, 
#количество прочтений в которых меньше, чем 4500пн
ps <- phyloseq(otu_table(seqtab2, taxa_are_rows=FALSE),
               sample_data(mdat),
               tax_table(taxa))
ps
ps <- prune_samples(sample_sums(ps)>=4500, ps)
ps
dna <- Biostrings::DNAStringSet(taxa_names(ps))
names(dna) <- taxa_names(ps)
ps <- merge_phyloseq(ps, dna)
taxa_names(ps) <- paste0("ASV", seq(ntaxa(ps)))
ps
random_tree = rtree(ntaxa(ps), rooted=TRUE, tip.label=taxa_names(ps))
#plot(random_tree) - можно визуализировать просто для проверки, что  предыдущий шаг отработал более-менее корректно
ps <- merge_phyloseq(ps, random_tree)
ps
#phy_tree(ps)
#не забудем сохранить готовый ps-объкт
saveRDS(ps, file='ps_obj.RData')
#достаем сохраненный ps-объкт, когда потребуется
ps <- readRDS(ps, file='ps_obj.RData')

#барплоты представленности различных фил в образце рисуем
physeq2 = filter_taxa(ps, function(x) mean(x) > 0.1, TRUE)
physeq3 = transform_sample_counts(physeq2, function(x) x / sum(x) )
ph_ps <- tax_glom(physeq3, taxrank = 'Phylum')
data <- as.data.frame(psmelt(ph_ps))
data$Phylum <- as.character(data$Phylum)
data$Phylum[data$Abundance < 0.01] <- "< 1% abund."
p <- ggplot(data, aes(x=Sample, y=Abundance, fill=Phylum))
p + geom_bar(aes(), stat="identity", position="stack") +
  scale_fill_manual(values = c("darkblue", "darkgoldenrod1", "darkseagreen", "darkorchid", "darkolivegreen1", "lightskyblue", "darkgreen", "deeppink", "khaki2", "firebrick", "brown1", "darkorange1", "cyan1", "royalblue4", "darksalmon", "darkblue",
                               "royalblue4", "dodgerblue3", "steelblue1", "lightskyblue", "darkseagreen", "darkgoldenrod1", "darkseagreen", "darkorchid", "darkolivegreen1", "brown1", "darkorange1", "cyan1", "darkgrey")) +
  theme(legend.position="bottom") + facet_wrap(~Culture + Variant, scales= "free_x", nrow=1) +
  theme(axis.text.x = element_text(angle = 90))

#распределение таксонов по основным по филам
wh0 = genefilter_sample(ps, filterfun_sample(function(x) x > 5), A=0.5*nsamples(ps))
ps1 = prune_taxa(wh0, ps)
ps1 = transform_sample_counts(ps1, function(x) 1E6 * x/sum(x))
phylum.sum = tapply(taxa_sums(ps1), tax_table(ps1)[, "Phylum"], sum, na.rm=TRUE)
top5phyla = names(sort(phylum.sum, TRUE))[1:5]
ps1 = prune_taxa((tax_table(ps1)[, "Phylum"] %in% top5phyla), ps1)
ps.ord <- ordinate(ps1, "NMDS", "bray")
p1 = plot_ordination(ps1, ps.ord, type="taxa", color="Phylum", title="taxa")
print(p1)
p1 + facet_wrap(~Phylum, 3)

#оценка влияния различных факторов
permanova.al <- function(ps, dist = "bray"){ # не обязательно использовать именно Брей-Кёртиса
  require(phyloseq)
  require(vegan)
  dist <- phyloseq::distance(ps, dist)
  metadata <- as(sample_data(ps), "data.frame")
  ad <- adonis2(dist ~ Variant*Culture*Lime, data = metadata)  #вместо Al известкование
  return(ad)
}
permanova.al(ps)
permanova_vologda <- permanova.al(ps)
#запишем результат в файлик, по желанию можно еще путь указать, куда сохранять
write.csv(permanova_vologda, "permanova_vologda.csv")


#######################################################################################
#альфа-разнообразие
#######################################################################################
#построение индексов альфа разнообразия
vologda_estimate_richness <- estimate_richness(ps, split = TRUE, measures = NULL)
write.csv(vologda_estimate_richness, "vologda_estimate_richness.csv")

#бокс плоты для индексов альфа распределения
PS <- prune_taxa(taxa_sums(ps) > 0, ps)
#alpha_meas = c("Observed", "Chao1", "ACE", "Shannon", "Simpson", "InvSimpson") - можно хоть все и сразу посмотреть
alpha_meas = c("Observed", "Shannon")
(p <- plot_richness(PS, "Variant", "Culture", measures=alpha_meas))
p + geom_boxplot(data=p$data, aes(x=Variant, y=value, color=NULL), alpha=0.1)


####################################################################################
#бетта-разнообразие
####################################################################################
#построение гистограмм и бетта-разнообразия
PSUF <- UniFrac(ps)
load(system.file("doc", "Unweighted_UniFrac.RData", package="phyloseq"))
PSoPa.pcoa = ordinate(ps, method="PCoA", distance=PSUF)
allGroupsColors<- c("grey0", "grey50", "dodgerblu", "deepskyblue","red", "darkred", "green", "green4" )
plot_scree(PSoPa.pcoa, "UniFrac/PCoA")

#в этой рисовалке можно выбрать, распределение по каким осям стоит отрисовать
#(p12 <- plot_ordination(ps, PSoPa.pcoa, "samples", color="Repeats") + 
#geom_point(size=5) + geom_path() + scale_colour_hue(guide = FALSE) )
(p12 <- plot_ordination(ps, PSoPa.pcoa, "samples", axes=c(1, 2),
                        color="Variant", shape="Culture") + geom_point(size=5) )


#еще немного порисуем, бетта-разнообразие в сравнении трех метрик
beta_custom_norm_NMDS_elli <- function(ps, seed = 7888, normtype="vst", color="Variant"){
  require(ggforce)
  require(phyloseq)
  require(ggplot2)
  require(ggpubr)
  require(DESeq2)
  # beta_NMDS <- function(){
  #normalisation. unifrac - rarefaction; wunifrac,bray - varstab
  diagdds = phyloseq_to_deseq2(ps, ~ Variant)
  diagdds = estimateSizeFactors(diagdds, type="poscounts")
  diagdds = estimateDispersions(diagdds, fitType = "local")
  if (normtype =="vst")
    pst <- varianceStabilizingTransformation(diagdds)
  if (normtype =="log")
    pst <- rlogTransformation(diagdds)
  pst.dimmed <- t(as.matrix(assay(pst)))
  pst.dimmed[pst.dimmed < 0.0] <- 0.0
  ps.varstab <- ps
  otu_table(ps.varstab) <- otu_table(pst.dimmed, taxa_are_rows = FALSE)
  ps.rand <- rarefy_even_depth(ps, rngseed = seed)
  #beta and ordination
  ordination.b <- ordinate(ps.varstab, "NMDS", "bray")
  ordination.u <- ordinate(ps.rand, "NMDS", "unifrac")
  ordination.w <- ordinate(ps.varstab, "NMDS", "wunifrac")
  #plotting
  p1 = plot_ordination(ps, ordination.b, type="sample", color, title="NMDS - Bray",
                       axes = c(1,2) ) + theme_bw() + theme(text = element_text(size = 10)) + geom_point(size = 3) +
    geom_mark_ellipse(aes(group = Culture, label = Culture ), label.fontsize = 10, label.buffer = unit(2, "mm"), label.minwidth = unit(5, "mm"),con.cap = unit(0.1, "mm"))
  p2 = plot_ordination(ps, ordination.u, type="sample", color, title="NMDS - unifrac",
                       axes = c(1,2) ) + theme_bw() + theme(text = element_text(size = 10)) + geom_point(size = 3) +
    geom_mark_ellipse(aes(group = Culture, label = Culture), label.fontsize = 10, label.buffer = unit(2, "mm"), label.minwidth = unit(5, "mm"),con.cap = unit(0.1, "mm"))
  p3 = plot_ordination(ps, ordination.w, type="sample", color, title="NMDS - wunifrac",
                       axes = c(1,2) ) + theme_bw() + theme(text = element_text(size = 10)) + geom_point(size = 3) +
    geom_mark_ellipse(aes(group = Culture, label = Culture), label.fontsize = 10, label.buffer = unit(2, "mm"), label.minwidth = unit(5, "mm"),con.cap = unit(0.1, "mm"))
  #merge by ggpubr
  p.all <- ggarrange(p1, p2, p3, ncol = 3 , nrow = 1, common.legend = TRUE, font.label = list(size = 12, face = "bold", color ="black"))
  return(p.all)
} 

beta_custom_norm_NMDS_elli(ps)


############################################################
#Определяем влияние фактора известкования
Des.soil.w.simper <- function(ps){
  require(DESeq2)
  require(vegan)
  require(tibble)
  diagdds = phyloseq_to_deseq2(ps, ~ Lime)
  diagdds = estimateSizeFactors(diagdds, type="poscounts")
  diagdds = estimateDispersions(diagdds, fitType = "local")
  diagdds = DESeq(diagdds)
  samp <-sample_data(ps)
  dds.counts <- diagdds@assays@.xData$data$counts
  dds.counts.df <- as.data.frame(dds.counts)
  aggdata <- t(aggregate.data.frame(as.data.frame(as.data.frame(t(diagdds@assays@.xData$data$mu))), by=list(samp$Repeats), median))
  colnames(aggdata) <- aggdata[1,]
  aggdata <- aggdata[-1,]
  res = results(diagdds)
  res.df <- as.data.frame(res)
  nice <- cbind(res.df,as.data.frame(tax_table(ps)[rownames(res.df),]), as.data.frame(aggdata)[rownames(res.df),])
  return(nice)
}
Des.soil.w.simper(ps) -> deseq_lime
#write.csv(des_non_simp, "des_non_simp.csv")


#переводим данные для чайма
otu = as.matrix(ps@otu_table)
otu <- t(otu)
otu_df = as.data.frame(otu)
write.table(otu_df, file = "otu_table.txt", sep = '\t', quote = FALSE)
system("sed -i '1s/^/#OTU_ID\t/' otu_table.txt")
tax_table_ps <- as.matrix(ps@tax_table)
tax_table_ps_df = as.data.frame(tax_table_ps)
write.table(tax_table_ps_df, file = "tax_table_ps_df.txt", sep = '\t', quote = FALSE)


#и немного табличек для построения деревьев
seqs <- colnames(seqtab2)
otab <- otu_table(seqtab2, taxa_are_rows=FALSE)
colnames(otab) <- paste0("seq", seq(ncol(otab)))
otab = t(otab)
write.table(seqs, "dada_seqs.txt",quote=FALSE)
write.table(otab, "dada_table.txt",quote=FALSE,sep="\t")
