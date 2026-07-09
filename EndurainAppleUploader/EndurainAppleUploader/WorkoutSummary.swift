//
//  WorkoutSummary.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import HealthKit

// MARK: - WorkoutSummary

struct WorkoutSummary: Identifiable {
    let id: UUID
    let activityTypeName: String
    let startDate: Date
    let endDate: Date
    let durationSeconds: TimeInterval
    let totalDistanceMeters: Double?
    let activeEnergyKcal: Double?
}

// MARK: - HKWorkoutActivityType display name

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .americanFootball:         return "Fútbol americano"
        case .archery:                  return "Tiro con arco"
        case .australianFootball:       return "Fútbol australiano"
        case .badminton:                return "Bádminton"
        case .baseball:                 return "Béisbol"
        case .basketball:               return "Baloncesto"
        case .bowling:                  return "Bolos"
        case .boxing:                   return "Boxeo"
        case .climbing:                 return "Escalada"
        case .crossTraining:            return "Entrenamiento cruzado"
        case .curling:                  return "Curling"
        case .cycling:                  return "Ciclismo"
        case .dance:                    return "Baile"
        case .elliptical:               return "Elíptica"
        case .equestrianSports:         return "Equitación"
        case .fencing:                  return "Esgrima"
        case .fishing:                  return "Pesca"
        case .functionalStrengthTraining: return "Entrenamiento funcional"
        case .golf:                     return "Golf"
        case .gymnastics:               return "Gimnasia"
        case .handball:                 return "Balonmano"
        case .hiking:                   return "Senderismo"
        case .hockey:                   return "Hockey"
        case .hunting:                  return "Caza"
        case .lacrosse:                 return "Lacrosse"
        case .martialArts:              return "Artes marciales"
        case .mindAndBody:              return "Mente y cuerpo"
        case .mixedMetabolicCardioTraining: return "Cardio mixto"
        case .paddleSports:             return "Deportes de remo"
        case .play:                     return "Juego"
        case .preparationAndRecovery:   return "Preparación y recuperación"
        case .racquetball:              return "Raquetbol"
        case .rowing:                   return "Remo"
        case .rugby:                    return "Rugby"
        case .running:                  return "Carrera"
        case .sailing:                  return "Vela"
        case .skatingSports:            return "Patinaje"
        case .snowSports:               return "Deportes de nieve"
        case .soccer:                   return "Fútbol"
        case .softball:                 return "Sóftbol"
        case .squash:                   return "Squash"
        case .stairClimbing:            return "Escalera"
        case .surfingSports:            return "Surf"
        case .swimming:                 return "Natación"
        case .tableTennis:              return "Tenis de mesa"
        case .tennis:                   return "Tenis"
        case .trackAndField:            return "Atletismo"
        case .traditionalStrengthTraining: return "Musculación"
        case .volleyball:               return "Voleibol"
        case .walking:                  return "Caminata"
        case .waterFitness:             return "Fitness acuático"
        case .waterPolo:                return "Waterpolo"
        case .waterSports:              return "Deportes acuáticos"
        case .wrestling:                return "Lucha"
        case .yoga:                     return "Yoga"
        case .barre:                    return "Barre"
        case .coreTraining:             return "Entrenamiento de core"
        case .crossCountrySkiing:       return "Esquí de fondo"
        case .downhillSkiing:           return "Esquí alpino"
        case .flexibility:              return "Flexibilidad"
        case .highIntensityIntervalTraining: return "HIIT"
        case .jumpRope:                 return "Salto a la comba"
        case .kickboxing:               return "Kickboxing"
        case .pilates:                  return "Pilates"
        case .snowboarding:             return "Snowboard"
        case .stairs:                   return "Escaleras"
        case .stepTraining:             return "Step"
        case .wheelchairWalkPace:       return "Silla de ruedas (paseo)"
        case .wheelchairRunPace:        return "Silla de ruedas (carrera)"
        case .taiChi:                   return "Tai chi"
        case .mixedCardio:              return "Cardio mixto"
        case .handCycling:              return "Handbike"
        case .discSports:               return "Deportes de disco"
        case .fitnessGaming:            return "Fitness gaming"
        case .cardioDance:              return "Cardio dance"
        case .socialDance:              return "Baile social"
        case .pickleball:               return "Pádel americano"
        case .cooldown:                 return "Recuperación"
        case .swimBikeRun:              return "Triatlón"
        case .transition:               return "Transición"
        case .underwaterDiving:         return "Buceo"
        case .other:                    return "Otro"
        @unknown default:               return "Desconocido"
        }
    }
}
