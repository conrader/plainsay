import Foundation

/// Closed EN/PL word lists for `ReplacementRuleValidator`. All lowercase,
/// NFC. Polish forms are the common case forms, not a full declension: the
/// validator only needs to notice that a date or number word changed.
enum ReplacementWordLists {
    static let dates = Set<String>([
        // EN weekdays, months, relative days and times of day
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "today", "tomorrow", "yesterday", "tonight", "morning", "afternoon", "evening",
        "noon", "midnight", "weekend",
        // PL weekdays (nominative, accusative, genitive, locative)
        "poniedziałek", "poniedziałku", "wtorek", "wtorku", "środa", "środę", "środy", "środzie",
        "czwartek", "czwartku", "piątek", "piątku", "sobota", "sobotę", "soboty", "sobocie",
        "niedziela", "niedzielę", "niedzieli",
        // PL months (nominative, genitive, locative)
        "styczeń", "stycznia", "styczniu", "luty", "lutego", "lutym", "marzec", "marca", "marcu",
        "kwiecień", "kwietnia", "kwietniu", "maj", "maja", "maju", "czerwiec", "czerwca", "czerwcu",
        "lipiec", "lipca", "lipcu", "sierpień", "sierpnia", "sierpniu", "wrzesień", "września",
        "wrześniu", "październik", "października", "październiku", "listopad", "listopada",
        "listopadzie", "grudzień", "grudnia", "grudniu",
        // PL relative days and times of day
        "dziś", "dzisiaj", "jutro", "jutra", "wczoraj", "pojutrze", "przedwczoraj",
        "rano", "rana", "wieczorem", "wieczór", "południe", "południa", "północy", "weekend",
    ])

    static let spelledNumbers = Set<String>([
        // EN cardinals and the ordinals used in dates
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "half", "quarter", "dozen",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        // PL cardinals (nominative plus common genitive forms)
        "jeden", "jedna", "jedno", "dwa", "dwie", "dwóch", "trzy", "trzech", "cztery", "czterech",
        "pięć", "pięciu", "sześć", "sześciu", "siedem", "siedmiu", "osiem", "ośmiu",
        "dziewięć", "dziewięciu", "dziesięć", "dziesięciu", "jedenaście", "dwanaście", "trzynaście",
        "czternaście", "piętnaście", "szesnaście", "siedemnaście", "osiemnaście", "dziewiętnaście",
        "dwadzieścia", "trzydzieści", "czterdzieści", "pięćdziesiąt", "sześćdziesiąt",
        "siedemdziesiąt", "osiemdziesiąt", "dziewięćdziesiąt", "sto", "dwieście", "trzysta",
        "czterysta", "pięćset", "tysiąc", "tysiące", "tysięcy", "milion", "miliony", "milionów",
        "pół", "półtora", "ćwierć",
        // PL ordinals used in dates (genitive: "piątego maja")
        "pierwszy", "pierwszego", "drugi", "drugiego", "trzeci", "trzeciego", "czwarty", "czwartego",
        "piąty", "piątego", "szósty", "szóstego", "siódmy", "siódmego", "ósmy", "ósmego",
        "dziewiąty", "dziewiątego", "dziesiąty", "dziesiątego",
    ])

    /// Short EN+PL function words. A rule whose `from` is only these would
    /// rewrite ordinary sentences, so it is never offered from one correction.
    static let functionWords = Set<String>([
        // EN
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for",
        "with", "from", "as", "is", "are", "was", "were", "be", "been", "am", "it", "its", "this",
        "that", "these", "those", "he", "she", "we", "you", "they", "i", "me", "my", "your", "our",
        "their", "his", "her", "them", "us", "not", "no", "so", "do", "does", "did", "have", "has",
        "had", "will", "would", "can", "could", "should", "may", "might", "must", "there", "here",
        "than", "then", "too", "very", "just", "also", "into", "out", "up", "off", "over", "about",
        "what", "which", "who", "when", "where", "why", "how", "all", "any", "some", "your", "yours",
        // PL
        "i", "a", "w", "we", "z", "ze", "na", "do", "od", "o", "u", "po", "za", "przy", "dla", "że",
        "to", "ten", "ta", "te", "tak", "nie", "się", "jest", "są", "był", "była", "było", "być",
        "jak", "ale", "lub", "albo", "czy", "co", "kto", "gdzie", "kiedy", "już", "jeszcze", "też",
        "tylko", "bardzo", "mnie", "mi", "ja", "ty", "on", "ona", "ono", "my", "wy", "oni", "one",
        "jego", "jej", "ich", "nas", "was", "go", "je", "mu", "tu", "tam", "przez", "pod", "nad",
        "przed", "bez", "aby", "żeby", "by", "nim", "niej", "tego", "tej", "tym",
    ])
}
