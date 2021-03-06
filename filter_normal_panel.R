#!/usr/bin/env Rscript

##########################################################################################
# Identify somatic variants in a MAF with sufficient support in a panel of curated normals
# and tag them with FILTER "normal_panel" in an output MAF
##########################################################################################

annotate_maf <- function(maf, fillout, normal.count) {

    maf[, tmp_id := stringr::str_c('chr', Chromosome,
                ':', Start_Position,
                '-', End_Position,
                ':', Reference_Allele,
                ':', Tumor_Seq_Allele1,
                ':', Tumor_Sample_Barcode)]

    maf <- merge(maf,fillout, by='tmp_id')

    fillout <- fillout[fillout$normal_panel_occurrences >= normal.count,]

    if (!('FILTER' %in% names(maf))) maf$FILTER = '.'
    normal_panel.blacklist <- unique(fillout$tmp_id)
    maf.annotated <- maf[, normal_panel := tmp_id %in% normal_panel.blacklist]
    maf.annotated <- maf[, FILTER := ifelse(normal_panel == TRUE & hotspot_whitelist == FALSE, ifelse((FILTER == '' | FILTER == '.' | FILTER == 'PASS' | is.na(FILTER) ), 'normal_panel', paste0(FILTER, ';normal_panel')), FILTER)]

    return(maf.annotated)
}

parse_fillout_vcf <- function(fillout) {

    # Convert GetBaseCountsMultiSample output
    fillout = melt(fillout, id.vars = colnames(fillout)[1:34], variable.name = 'Tumor_Sample_Barcode') %>%
            separate(value, into = c('n_depth','n_ref_count','n_alt_count','n_var_freq'), sep = ';') %>%
            mutate(n_depth = str_extract(n_depth, regex('[0-9].*'))) %>%
            mutate(n_ref_count = str_extract(n_ref_count, regex('[0-9].*'))) %>%
            mutate(n_alt_count = str_extract(n_alt_count, regex('[0-9].*'))) %>%
            mutate(n_var_freq = str_extract(n_var_freq, regex('[0-9].*'))) %>%
            mutate(TAG = stringr::str_c('chr', Chrom, ':', Start, '-', Start, ':', Ref, ':', Alt))

    # Note, variant might be present multiple times if occuring in more than one sample, fix this
    # at the fillout step by de-duping the MAF
    fillout = mutate(fillout, tmp_id = stringr::str_c(Tumor_Sample_Barcode, Chrom, Start, Ref, Alt, Gene))
    fillout = fillout[!duplicated(fillout$tmp_id),]

    # Calculate frequencies and return
    return(group_by(fillout, TAG) %>% summarize(normal_count = sum(n_alt_count>=1)))
}

parse_fillout_maf <- function(maf, fillout, chosen.proportion, min_tpvf) {

    fillout[, TAG := stringr::str_c('chr', Chromosome,
                    ':', Start_Position,
                    '-', End_Position,
                    ':', Reference_Allele,
                    ':', Tumor_Seq_Allele1)]
    fillout[, tmp_id := stringr::str_c('chr', Chromosome,
                    ':', Start_Position,
                    '-', End_Position,
                    ':', Reference_Allele,
                    ':', Tumor_Seq_Allele1,
                    ':', Tumor_Sample_Barcode)]
    fillout = fillout[!duplicated(fillout$tmp_id),]

    if (!('TAG' %in% names(maf))) {
    maf[, TAG := stringr::str_c('chr', Chromosome,
                        ':', Start_Position,
                        '-', End_Position,
                        ':', Reference_Allele,
                        ':', Tumor_Seq_Allele2)]
    }
    maf[, tmp_id := stringr::str_c('chr', Chromosome,
                    ':', Start_Position,
                    '-', End_Position,
                    ':', Reference_Allele,
                    ':', Tumor_Seq_Allele1,
                    ':', Tumor_Sample_Barcode)]

    # Calculate tumor VAF and from that the required TPVF
    maf$t_alt_count[maf$t_alt_count=='.'] <- 0
    maf$t_alt_count<- as.numeric(maf$t_alt_count)
    maf$vaf <- maf$t_alt_count / maf$t_depth
    maf$tpvf <- maf$vaf / chosen.proportion
    maf$tpvf[maf$tpvf < min_tpvf] <- min_tpvf
    maf.shortlist<-select(maf,TAG,tmp_id,tpvf)

    # Compare each normal panel VAF to the TPVF and count occurrences
    normpanel<-select(fillout,TAG,t_variant_frequency,t_alt_count)
    normpanel <- normpanel[normpanel$t_alt_count >= 1,]
    fulljoin.maf<-full_join(maf.shortlist,normpanel,by='TAG')
    fulljoin.maf$normal_panel_occurrences <- fulljoin.maf$t_variant_frequency >= fulljoin.maf$tpvf
    normalpanel_df <- group_by(fulljoin.maf,tmp_id) %>% summarize(normal_panel_occurrences=sum(normal_panel_occurrences),normal_panel_mean_alt_count=mean(t_alt_count))
    normalpanel_df[is.na(normalpanel_df)] <- 0
    normalpanel_df$normal_panel_mean_alt_count <- round(normalpanel_df$normal_panel_mean_alt_count)
    return(normalpanel_df)
}

if( ! interactive() ) {

    pkgs = c('data.table', 'argparse', 'reshape2', 'dplyr', 'tidyr', 'stringr')
    junk <- lapply(pkgs, function(p){suppressPackageStartupMessages(require(p, character.only = T))})
    rm(junk)

    parser=ArgumentParser()
    parser$add_argument('-m', '--maf', type='character', default='stdin', help='MAF format file listing predicted somatic events')
    parser$add_argument('-f', '--fillout', type='character', help='Output file generated by GetBaseCountsMultiSample for the same somatic events')
    parser$add_argument('-fo', '--fillout_format', type='double', default=1, help='GetBaseCountsMultiSample output format. MAF-like (1) or VCF-like (2) (Default: 1)')
    parser$add_argument('-c', '--chosen_proportion', type='double', default=10, help='Tumor VAF divided by this produces the tumor proportional variant fraction (TPVF) (Default: 10)')
    parser$add_argument('-t', '--min_tpvf', type='double', default=0.001, help='Minimum TPVF that a normal VAF must exceed to be considered occurring in the normal (Default: 0.001)')
    parser$add_argument('-n', '--normal_count', type='double', default=5, help='Minimum number of normal samples that must have VAF>=TPVF (5)')
    parser$add_argument('-o', '--outfile', type='character', default='stdout', help='Output file')
    args=parser$parse_args()

    maf <- suppressWarnings(fread(args$maf, colClasses=c(Chromosome="character"), showProgress = F))
    fillout <- suppressWarnings(fread(args$fillout, colClasses=c(Chromosome="character"), showProgress = F))
    fillout.format<-args$fillout_format
    normal.count <- args$normal_count
    chosen.proportion <- args$chosen_proportion
    min_tpvf <- args$min_tpvf
    outfile <- args$outfile

    if(fillout.format == 2) {
        parsed_fillout = parse_fillout_vcf(fillout)
        maf.out <- annotate_maf(maf, parsed_fillout, normal.count)

    }
    else {
        parsed_fillout = parse_fillout_maf(maf,fillout,chosen.proportion,min_tpvf)
        maf.out <- annotate_maf(maf, parsed_fillout, normal.count)
    }

    # Write the new tagged MAF in output, excluding a few unimportant columns
    maf.out$normal_panel <- NULL
    maf.out$TAG<- NULL
    maf.out$tmp_id<- NULL
    if (outfile == 'stdout') {
        write.table(maf.out, stdout(), na="", sep = "\t", col.names = T, row.names = F, quote = F)
    }
    else {
        write.table(maf.out, outfile, na="", sep = "\t", col.names = T, row.names = F, quote = F)
    }
}
